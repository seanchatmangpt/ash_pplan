defmodule AshPPlan.Reactor.Durable.LedgerOCELHardeningTest do
  @moduledoc """
  Hardening court for `LedgerOCEL` + `ProcessEvidence` under the burn-in workload.

  Real stores (Store.Ets, Store.Dets), real Engine, no mocks. Adversarial angles:

  1. 10k-event export memory profile — no leak, no unbounded accumulator.
  2. Export under concurrent appends — every snapshot is valid OCEL JSON, unique event ids,
     non-decreasing seqs (no torn digest, no seq gaps).
  3. Digest stability — same standing content yields the same digest across repeated calls,
     across Ets and Dets stores, and across map-key insertion order in checkpoint outputs.
  4. Malformed attributes — map/tuple/struct attribute values export instead of crashing
     (fix-forward: `value_to_s/1` inspect fallback in `ProcessEvidence.export/2`).
  5. Duplicate seqs, nil outputs and non-terminal runs don't break export/digest.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.ProcessEvidence
  alias AshPPlan.ProcessEvidence.Event
  alias AshPPlan.Reactor.Durable.LedgerOCEL
  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.Reactor.Durable.Store.Ets

  @subject "sha256:" <> String.duplicate("cd", 32)
  @ets_name AshPPlan.Reactor.Durable.LedgerOCELHardeningTest.Ets

  setup do
    {:ok, ets} = Ets.start_link(name: @ets_name)

    on_exit(fn ->
      case GenServer.whereis(@ets_name) do
        nil -> :ok
        pid -> stop_quiet(pid)
      end
    end)

    %{ets: ets}
  end

  # -- fixtures --------------------------------------------------------------------------------

  defp dets_store(tag \\ :plain, variant \\ 0) do
    path = dets_path_for(tag, variant)
    {:ok, pid} = Dets.start_link(path: path)

    on_exit(fn ->
      stop_quiet(pid)
      File.rm(path)
    end)

    pid
  end

  defp dets_path_for(tag, variant) do
    Path.join(
      System.tmp_dir!(),
      "ash_pplan_ocel_hard_#{tag}_#{variant}_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}.dets"
    )
  end

  defp stop_quiet(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp populate(store, store_module, id, n, key_order \\ :forward) do
    {:ok, _} = store_module.start_run(store, %{id: id, model: :m, bindings: %{a: 1}})

    outputs =
      case key_order do
        :forward -> for i <- 1..n, do: Map.new([{:z, i}, {:a, i}])
        :reverse -> for i <- 1..n, do: Map.new([{:a, i}, {:z, i}])
      end

    for i <- 1..n do
      store_module.record(store, id, "k#{i}", "step#{i}", Enum.at(outputs, i - 1), %{
        impl: Foo,
        args: %{}
      })
    end

    store_module.transition(store, id, [:pending], :completed, %{})
    :ok
  end

  defp synthetic_events(n) do
    for i <- 1..n do
      %Event{
        id: "run:x/#{i}",
        activity: "task_succeeded",
        timestamp: ~U[2026-01-01 00:00:00.000Z],
        objects: [{"WorkflowRun", "run:x", "run"}, {"Step", "step:#{i}", "step"}],
        attributes: %{task: "step#{i}", seq: i, output_digest: String.duplicate("ab", 32)},
        subject_id: @subject
      }
    end
  end

  # -- 1. 10k-event export memory profile ------------------------------------------------------

  @tag :burn_in
  test "10k-event export: bounded process-memory delta, no unbounded accumulator" do
    events = synthetic_events(10_000)

    :erlang.garbage_collect()
    {_, before} = Process.info(self(), :memory)

    assert {:ok, json} = ProcessEvidence.export(events, :ocel2_json)

    :erlang.garbage_collect()
    {_, after_b} = Process.info(self(), :memory)

    assert byte_size(json) > 1_000_000
    assert %{"events" => evs} = Jason.decode!(json)
    assert length(evs) == 10_000

    # retained delta after GC is the result itself plus noise; a leak or an unbounded
    # intermediate accumulator would retain an order of magnitude more
    assert after_b - before < 64 * 1024 * 1024
  end

  @tag :burn_in
  test "LedgerOCEL over a 10k-checkpoint run: events, export and digest all complete" do
    store = @ets_name
    populate(store, Ets, "burn10k", 10_000)

    assert {:ok, events} = LedgerOCEL.events(store, "burn10k")
    assert length(events) == 10_002

    seqs = Enum.map(events, & &1.attributes[:seq])
    assert seqs == Enum.sort(seqs)

    assert {:ok, json} = LedgerOCEL.export(store, "burn10k")
    assert {:ok, d1} = LedgerOCEL.digest(store, "burn10k")
    assert {:ok, d2} = LedgerOCEL.digest(store, "burn10k")
    assert d1 == d2

    assert {:ok, parsed} = Jason.decode(json)
    assert length(parsed["events"]) == 10_002
  end

  # -- 2. export under concurrent appends ------------------------------------------------------

  @tag :burn_in
  test "export stays consistent while checkpoints append concurrently" do
    store = @ets_name
    {:ok, _} = Ets.start_run(store, %{id: "race1", model: :m, bindings: %{}})
    parent = self()

    appender =
      spawn(fn ->
        for i <- 1..2_000 do
          Ets.record(store, "race1", "k#{i}", "step#{i}", %{i: i}, %{impl: Foo, args: %{}})
        end

        send(parent, :appends_done)
      end)

    exports =
      Stream.repeatedly(fn -> LedgerOCEL.export(store, "race1") end)
      |> Stream.take_while(fn _ -> Process.alive?(appender) end)
      |> Enum.to_list()

    got =
      receive do
        msg -> msg
      after
        30_000 -> flunk("appender never signalled completion")
      end

    assert got == :appends_done

    assert exports != []

    for {:ok, json} <- exports do
      assert {:ok, %{"events" => evs}} = Jason.decode(json)

      ids = Enum.map(evs, & &1["id"])
      assert ids == Enum.uniq(ids)

      seqs =
        for e <- evs,
            %{"value" => s} <-
              Enum.filter(e["attributes"], &(&1["name"] == "seq")),
            do: String.to_integer(s)

      assert seqs == Enum.sort(seqs)
    end

    assert {:ok, events} = LedgerOCEL.events(store, "race1")
    assert length(events) == 2_001
  end

  # -- 3. digest stability ---------------------------------------------------------------------

  test "digest is stable across repeated calls, stores and map-key insertion order" do
    # one fresh store per variant, same run id everywhere, so run-bound event ids do not
    # leak into the comparison
    results =
      for {mod, tag} <- [{Ets, :e}, {Dets, :d}], key_order <- [:forward, :reverse] do
        {:ok, store} =
          if mod == Ets do
            Ets.start_link()
          else
            Dets.start_link(path: dets_path_for(tag, key_order))
          end

        on_exit(fn -> stop_quiet(store) end)
        populate(store, mod, "dsame", 3, key_order)
        {:ok, d} = LedgerOCEL.digest(store, "dsame")
        {:ok, j} = LedgerOCEL.export(store, "dsame")
        {d, j}
      end

    {digests, jsons} = Enum.unzip(results)
    assert Enum.count(Enum.uniq(digests)) == 1

    # `time` fields are export-time by design; compare everything else
    assert Enum.count(Enum.uniq(Enum.map(jsons, &strip_times/1))) == 1
  end

  test "digest tracks a change to the standing set" do
    store = @ets_name
    {:ok, _} = Ets.start_run(store, %{id: "dig1", model: :m, bindings: %{}})
    Ets.record(store, "dig1", "k1", "step1", %{x: 1}, %{impl: Foo, args: %{}})
    {:ok, before} = LedgerOCEL.digest(store, "dig1")

    Ets.record(store, "dig1", "k2", "step2", %{changed: true}, %{impl: Foo, args: %{}})
    {:ok, after_b} = LedgerOCEL.digest(store, "dig1")
    refute before == after_b
  end

  test "nil checkpoint outputs export and digest cleanly" do
    store = @ets_name
    {:ok, _} = Ets.start_run(store, %{id: "nilout", model: :m, bindings: %{}})
    Ets.record(store, "nilout", "k1", "step1", nil, %{impl: Foo, args: %{}})
    Ets.transition(store, "nilout", [:pending], :completed, %{})

    assert {:ok, events} = LedgerOCEL.events(store, "nilout")
    assert Enum.any?(events, &(&1.activity == "task_succeeded"))

    assert {:ok, json} = LedgerOCEL.export(store, "nilout")
    assert json =~ "output_digest"
  end

  # -- 4. malformed attributes -----------------------------------------------------------------

  test "map/tuple attribute values export instead of crashing" do
    events = [
      %Event{
        id: "run:m/1",
        activity: "task_succeeded",
        timestamp: ~U[2026-01-01 00:00:00.000Z],
        objects: [{"WorkflowRun", "run:m", "run"}],
        attributes: %{task: "t", seq: 1, payload: %{nested: %{a: 1}}, tup: {:x, 1}},
        subject_id: @subject
      }
    ]

    assert {:ok, json} = ProcessEvidence.export(events, :ocel2_json)
    assert json =~ "nested"
  end

  test "nil subject_id and nil attribute values export without crashing" do
    events = [
      %Event{
        id: "run:n/1",
        activity: "run_started",
        timestamp: ~U[2026-01-01 00:00:00.000Z],
        objects: [{"WorkflowRun", "run:n", "run"}],
        attributes: %{plan: nil, seq: 0},
        subject_id: nil
      }
    ]

    assert {:ok, json} = ProcessEvidence.export(events, :ocel2_json)
    assert json =~ "\"plan\""
  end

  # -- 5. duplicate seqs / lifecycle edges -----------------------------------------------------

  test "duplicate seq values across events export and keep event ids unique" do
    events =
      for tag <- [:a, :b] do
        %Event{
          id: "run:d/#{tag}",
          activity: "task_succeeded",
          timestamp: ~U[2026-01-01 00:00:00.000Z],
          objects: [{"WorkflowRun", "run:d", "run"}],
          attributes: %{task: to_string(tag), seq: 5},
          subject_id: @subject
        }
      end

    assert {:ok, json} = ProcessEvidence.export(events, :ocel2_json)
    assert {:ok, %{"events" => evs}} = Jason.decode(json)
    assert length(evs) == 2

    ids = Enum.map(evs, & &1["id"])
    assert ids == Enum.uniq(ids)
  end

  test "non-terminal run exports without run_ended; completed run carries seq = max + 1" do
    store = @ets_name
    {:ok, _} = Ets.start_run(store, %{id: "nt1", model: :m, bindings: %{}})
    Ets.record(store, "nt1", "k1", "step1", %{x: 1}, %{impl: Foo, args: %{}})

    assert {:ok, events} = LedgerOCEL.events(store, "nt1")
    refute Enum.any?(events, &(&1.activity == "run_ended"))

    assert {:ok, _} = Ets.transition(store, "nt1", [:pending], :completed, %{})
    assert {:ok, events2} = LedgerOCEL.events(store, "nt1")

    assert [%{activity: "run_ended", attributes: %{seq: 3}}] =
             Enum.filter(events2, &(&1.activity == "run_ended"))
  end

  test "Dets-backed run exports identically across a store restart on the same file" do
    store = dets_store()
    populate(store, Dets, "persist1", 5)
    {:ok, d_before} = LedgerOCEL.digest(store, "persist1")
    {:ok, j_before} = LedgerOCEL.export(store, "persist1")
    path = :sys.get_state(store).path

    GenServer.stop(store)
    {:ok, store2} = Dets.start_link(path: path)

    # digest covers {id, activity, attributes} only, so it is byte-stable across restarts;
    # the export's `time` fields are export-time by design, so compare it time-stripped
    assert {:ok, ^d_before} = LedgerOCEL.digest(store2, "persist1")

    assert {:ok, j_after} = LedgerOCEL.export(store2, "persist1")
    assert strip_times(j_before) == strip_times(j_after)
  end

  defp strip_times(json) do
    json
    |> Jason.decode!()
    |> update_in(["events"], fn evs ->
      Enum.map(evs, &Map.delete(&1, "time"))
    end)
    |> Jason.encode!()
  end
end
