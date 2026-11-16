defmodule AshPPlan.MirrorSim.TelemetryTest do
  @moduledoc """
  Wire courts for the mirror-sim `/telemetry` area. Evidence is pulled over a real Bandit
  socket as NDJSON / OCEL JSON and validated with pm4exunit; a mutated event order flips
  conformance. Replay timestamps are derived from the wire `seq` (deterministic ascending).
  """
  use ExUnit.Case, async: false
  use Pm4ExUnit

  alias AshPPlan.MirrorSim.{Server, Telemetry}
  alias AshPPlan.ProcessEvidence
  alias AshPPlan.ProcessEvidence.Ex4pm
  alias AshPPlan.Telemetry.Emit.BufferingEmitter
  alias AshPPlan.Telemetry.Emit.Event, as: E

  @declared [:lease_granted, :checkpoint_committed, :receipt_observed, :lease_released]

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    Telemetry.stop_buffer()
    on_exit(&Telemetry.stop_buffer/0)
    pid = start_supervised!({Server, port: 0})
    {:ok, base: Server.base_url(pid)}
  end

  defp http(method, base, path, body \\ nil) do
    url = String.to_charlist(base <> path)

    req =
      case method do
        :get -> {url, []}
        :post -> {url, [], ~c"application/json", body}
      end

    {:ok, {{_, status, _}, _h, resp}} =
      :httpc.request(method, req, [], body_format: :binary)

    {status, resp}
  end

  defp post_json(base, path, map) do
    {s, b} = http(:post, base, path, Jason.encode!(map))
    {s, Jason.decode!(b)}
  end

  defp emit_scenario(base) do
    for body <- [
          %{"type" => "lease_granted", "topic" => "r1", "lease_id" => "L1", "owner" => "w"},
          %{
            "type" => "checkpoint_committed",
            "topic" => "r1",
            "run_id" => "r1",
            "store" => "ets",
            "step_count" => 2
          },
          %{
            "type" => "receipt_observed",
            "topic" => "r1",
            "run_id" => "r1",
            "receipt_id" => "rc1"
          },
          %{"type" => "lease_released", "topic" => "r1", "lease_id" => "L1", "owner" => "w"}
        ] do
      assert {200, %{"emitted" => true}} = post_json(base, "/telemetry/emit", body)
    end
  end

  defp drain(base) do
    {200, body} = http(:get, base, "/telemetry/drain")
    body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp replay(session, acts_with_seq) do
    base = ~U[2026-11-16 00:00:00Z]

    Enum.each(acts_with_seq, fn {act, seq} ->
      emit_event(session, "e#{seq}", act, timestamp: DateTime.add(base, seq, :second))
    end)
  end

  defp acts(envs), do: Enum.map(envs, &{String.to_atom(&1["type"]), &1["seq"]})

  test "wire NDJSON evidence conforms to declared order; seq is gapless", %{
    base: base,
    pm4_session: s
  } do
    emit_scenario(base)
    envs = drain(base)

    assert Enum.map(envs, & &1["seq"]) == [1, 2, 3, 4]
    assert Enum.map(envs, &String.to_atom(&1["type"])) == @declared

    replay(s, acts(envs))
    assert_conformance(s, [@declared])
    refute_conformance(s, [Enum.reverse(@declared)])
  end

  test "mutated event order flips conformance", %{base: base, pm4_session: s} do
    emit_scenario(base)
    envs = drain(base)
    [{a1, q1}, {a2, q2}, {a3, q3}, {a4, q4}] = acts(envs)

    # swap activities at seq 2 and 3, keep timestamps ascending
    replay(s, [{a1, q1}, {a3, q2}, {a2, q3}, {a4, q4}])
    refute_conformance(s, [@declared])

    assert_conformance(s, [
      [:lease_granted, :receipt_observed, :checkpoint_committed, :lease_released]
    ])
  end

  test "parity: wire envelopes equal a direct BufferingEmitter run", %{base: base} do
    emit_scenario(base)
    wire = drain(base)

    {:ok, direct} = BufferingEmitter.start_link(name: :mirror_telemetry_direct)

    for ev <- [
          E.lease_granted("L1", owner: "w"),
          E.checkpoint_committed("r1", "ets", step_count: 2),
          E.receipt_observed("r1", "rc1"),
          E.lease_released("L1", owner: "w")
        ] do
      :ok = BufferingEmitter.emit(ev, topic: "r1", server: direct)
    end

    envs = BufferingEmitter.drain(direct)
    GenServer.stop(direct)

    assert Enum.map(wire, &{&1["seq"], &1["type"], &1["topic"], &1["run_id"]}) ==
             Enum.map(envs, &{&1.seq, to_string(&1.type), &1.topic, &1.run_id})

    cp = Enum.find(wire, &(&1["type"] == "checkpoint_committed"))
    assert cp["data"]["store"] == "ets"
    assert cp["data"]["step_count"] == 2
  end

  test "counts reflect buffered types and drain resets", %{base: base} do
    emit_scenario(base)
    {200, body} = http(:get, base, "/telemetry/counts")
    c = Jason.decode!(body)
    assert c["buffered"] == 4
    assert c["by_type"]["lease_granted"] == 1
    assert length(drain(base)) == 4
    {200, body} = http(:get, base, "/telemetry/counts")
    assert Jason.decode!(body)["buffered"] == 0
  end

  test "typed refusals: unknown type, missing field, malformed JSON", %{base: base} do
    assert {422, %{"refused" => true, "broken_term" => "unknown_event_type"}} =
             post_json(base, "/telemetry/emit", %{"type" => "nope", "topic" => "t"})

    assert {422, %{"refused" => true, "broken_term" => "missing_field"}} =
             post_json(base, "/telemetry/emit", %{"type" => "run_status_changed", "topic" => "t"})

    assert {400, body} = http(:post, base, "/telemetry/emit", "{not json")
    assert %{"refused" => true} = Jason.decode!(body)
  end

  @ocel_events [
    %{
      "id" => "ev1",
      "activity" => "task_attempted",
      "timestamp" => "2026-11-16T00:00:01Z",
      "objects" => [["WorkflowRun", "run:1", "run"]],
      "attributes" => %{"task" => "a", "n" => 3},
      "subject_id" => "s1"
    },
    %{
      "id" => "ev2",
      "activity" => "task_succeeded",
      "timestamp" => "2026-11-16T00:00:02Z",
      "objects" => [["WorkflowRun", "run:1", "run"]],
      "attributes" => %{"task" => "a", "n" => 4},
      "subject_id" => "s1"
    }
  ]

  defp direct_events do
    for m <- @ocel_events do
      {:ok, dt, _} = DateTime.from_iso8601(m["timestamp"])

      %ProcessEvidence.Event{
        id: m["id"],
        activity: m["activity"],
        timestamp: dt,
        objects: Enum.map(m["objects"], &List.to_tuple/1),
        attributes: m["attributes"],
        subject_id: m["subject_id"]
      }
    end
  end

  test "OCEL export parity (corrected and legacy) and ex4pm round trip conformance",
       %{base: base, pm4_session: s} do
    {200, corrected} =
      http(:post, base, "/telemetry/ocel/export", Jason.encode!(%{"events" => @ocel_events}))

    assert {:ok, ^corrected} = ProcessEvidence.export(direct_events(), :ocel2_json, [])

    {200, legacy} =
      http(
        :post,
        base,
        "/telemetry/ocel/export",
        Jason.encode!(%{"events" => @ocel_events, "legacy" => true})
      )

    assert {:ok, ^legacy} = ProcessEvidence.export(direct_events(), :ocel2_json)
    refute legacy == corrected

    assert Ex4pm.available?()

    {200, ex_json} =
      http(:post, base, "/telemetry/ocel/ex4pm", Jason.encode!(%{"events" => @ocel_events}))

    assert {:ok, ^ex_json} = Ex4pm.export(direct_events(), :ocel2_json, [])

    {200, parsed} =
      http(:post, base, "/telemetry/ocel/parse", Jason.encode!(%{"json" => ex_json}))

    evs = Jason.decode!(parsed)["events"]
    assert Enum.map(evs, & &1["activity"]) == ["task_attempted", "task_succeeded"]

    acts =
      evs |> Enum.with_index(1) |> Enum.map(fn {e, i} -> {String.to_atom(e["activity"]), i} end)

    replay(s, acts)
    assert_conformance(s, [[:task_attempted, :task_succeeded]])
    refute_conformance(s, [[:task_succeeded, :task_attempted]])
  end

  test "OCEL export refuses bad timestamp and bad object triples", %{base: base} do
    bad_ts = [%{hd(@ocel_events) | "timestamp" => "yesterday"}]

    assert {422, %{"refused" => true, "broken_term" => "invalid_timestamp"}} =
             post_json(base, "/telemetry/ocel/export", %{"events" => bad_ts})

    bad_obj = [%{hd(@ocel_events) | "objects" => [["only", "two"]]}]

    assert {422, %{"refused" => true, "broken_term" => "bad_object"}} =
             post_json(base, "/telemetry/ocel/export", %{"events" => bad_obj})

    assert {422, %{"refused" => true}} = post_json(base, "/telemetry/ocel/parse", %{})
  end

  test "surfaces/0 routes all live under /telemetry" do
    assert Enum.all?(Telemetry.surfaces(), &String.starts_with?(&1.route, "/telemetry/"))
  end
end
