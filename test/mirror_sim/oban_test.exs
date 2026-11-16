defmodule AshPPlan.MirrorSim.ObanTest do
  use ExUnit.Case, async: false

  alias AshPPlan.MirrorSim.Oban, as: Sim
  alias AshPPlan.MirrorSim.Server

  @resource AshPPlan.ObanIntegrationResource
  @deadline_ms 5_000

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, pid} = Server.start_link(port: 0)
    base = Server.base_url(pid)
    await_health!(base)
    {:ok, base: base}
  end

  defp await_health!(base) do
    deadline = System.monotonic_time(:millisecond) + @deadline_ms
    poll(deadline, fn -> match?({200, _}, get(base, "/health")) end, "health")
  end

  defp poll(deadline, fun, what) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("poll timed out: #{what}")
      true -> poll(deadline, fun, what)
    end
  end

  defp get(base, path) do
    {:ok, {{_, status, _}, _h, body}} =
      :httpc.request(:get, {String.to_charlist(base <> path), []}, [], body_format: :binary)

    {status, decode(body)}
  end

  defp post(base, path, payload) do
    {:ok, {{_, status, _}, _h, body}} =
      :httpc.request(
        :post,
        {String.to_charlist(base <> path), [], ~c"application/json", Jason.encode!(payload)},
        [],
        body_format: :binary
      )

    {status, decode(body)}
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, v} -> v
      _ -> body
    end
  end

  test "surfaces are listed by the router", %{base: base} do
    assert {200, %{"mounted" => mounted}} = get(base, "/surfaces")
    assert Enum.any?(mounted, &(&1["area"] == "oban"))
    assert length(Sim.surfaces()) == 7
  end

  test "describe/activations/capabilities equal the direct call", %{base: base} do
    {:ok, direct} = AshPPlan.Oban.describe_resource(@resource)
    assert {200, %{"ok" => wire}} = get(base, "/oban/describe")
    assert wire == Jason.decode!(Jason.encode!(Sim.jsonable(direct)))

    {:ok, acts} = AshPPlan.Oban.activations(@resource)
    assert {200, %{"ok" => wire_acts}} = get(base, "/oban/activations")
    assert Enum.map(wire_acts, & &1["name"]) == Enum.map(acts, &Atom.to_string(&1.name))

    {:ok, caps} = AshPPlan.Oban.capabilities(@resource)
    assert {200, %{"ok" => wire_caps}} = get(base, "/oban/capabilities")
    assert wire_caps["retry_delivery?"] == caps.retry_delivery?
    assert wire_caps["actor_persistence?"] == caps.actor_persistence?
    assert wire_caps["retry_delivery?"] == true
  end

  test "fetch_activation returns trigger and schedule; unknown is refused", %{base: base} do
    assert {200, %{"ok" => %{"kind" => "trigger", "name" => "process"}}} =
             get(base, "/oban/activation?name=process")

    assert {200, %{"ok" => %{"kind" => "scheduled_action", "name" => "tick"}}} =
             get(base, "/oban/activation?name=tick")

    assert {422, %{"refused" => true, "broken_term" => "unknown_ash_oban_activation"}} =
             get(base, "/oban/activation?name=nope")
  end

  test "non-Oban and unknown resources are typed refusals", %{base: base} do
    assert {422, %{"refused" => true, "broken_term" => "ash_oban_not_configured"}} =
             get(base, "/oban/describe?resource=AshPPlan.DescriptorFixtures.PlainResource")

    assert {422, %{"refused" => true, "broken_term" => "unknown_resource"}} =
             get(base, "/oban/describe?resource=Elixir.File")
  end

  test "construct builds an uninserted job changeset (enqueue boundary)", %{base: base} do
    assert {200, %{"ok" => job}} = post(base, "/oban/construct", %{"trigger" => "process"})
    assert job["valid"] == true
    assert job["inserted"] == false
    assert job["worker"] =~ "ProcessWorker"
    assert job["max_attempts"] == 3
  end

  test "construct refuses unknown triggers, including scheduled actions", %{base: base} do
    assert {422, %{"broken_term" => "unknown_ash_oban_trigger"}} =
             post(base, "/oban/construct", %{"trigger" => "missing"})

    assert {422, %{"broken_term" => "unknown_ash_oban_trigger"}} =
             post(base, "/oban/construct", %{"trigger" => "tick"})

    assert {422, %{"broken_term" => "ash_oban_not_configured"}} =
             post(base, "/oban/construct", %{
               "trigger" => "process",
               "resource" => "AshPPlan.DescriptorFixtures.PlainResource"
             })
  end

  test "observation classifies perform/retry outcomes equal to the direct call", %{base: base} do
    cases = [
      {%{"kind" => "ok"}, :ok},
      {%{"kind" => "snooze", "value" => 5}, {:snooze, 5}},
      {%{"kind" => "snooze", "value" => [2, "minutes"]}, {:snooze, {2, :minutes}}},
      {%{"kind" => "cancel", "value" => "stop"}, {:cancel, "stop"}},
      {%{"kind" => "discard"}, :discard},
      {%{"kind" => "error", "value" => "boom"}, {:error, "boom"}},
      {%{"kind" => "other", "value" => "x"}, "x"}
    ]

    for {payload, term} <- cases do
      assert {200, wire} = post(base, "/oban/observation", payload)
      expected = term |> AshPPlan.Oban.observation() |> Sim.jsonable()
      assert wire == Jason.decode!(Jason.encode!(expected)), inspect(payload)
    end

    assert {200, %{"state" => "failed", "retryable?" => true}} =
             post(base, "/oban/observation", %{"kind" => "error", "value" => "boom"})

    assert {200, %{"state" => "snoozed", "terminal?" => false}} =
             post(base, "/oban/observation", %{"kind" => "snooze", "value" => 5})

    assert {422, %{"broken_term" => "unknown_observation_kind"}} =
             post(base, "/oban/observation", %{"kind" => "bogus"})
  end

  test "Action.Run refusals over the wire", %{base: base} do
    assert {422, %{"broken_term" => "missing_action_argument"}} =
             post(base, "/oban/run", %{"arguments" => %{}})

    assert {422, %{"broken_term" => "plan_not_allowed"}} =
             post(base, "/oban/run", %{
               "opts" => %{"plans" => ["urn:allowed"]},
               "arguments" => %{"plan_iri" => "urn:other"}
             })

    assert {422, %{"broken_term" => "handlers_argument_refused"}} =
             post(base, "/oban/run", %{
               "opts" => %{"handlers" => true},
               "arguments" => %{"plan_iri" => "urn:p", "handlers" => %{"a" => "b"}}
             })

    assert {422, %{"broken_term" => "invalid_action_options"}} =
             post(base, "/oban/run", %{"opts" => %{"plans" => [1]}})
  end

  test "malformed JSON is a 4xx refusal, not a 500", %{base: base} do
    {:ok, {{_, status, _}, _h, _body}} =
      :httpc.request(
        :post,
        {String.to_charlist(base <> "/oban/observation"), [], ~c"application/json", "{bad"},
        [],
        body_format: :binary
      )

    assert status in 400..499
  end
end
