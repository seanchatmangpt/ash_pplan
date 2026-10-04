defmodule AshPPlan.Fleet.OcelPipelineSoakTest do
  @moduledoc """
  FLEET lane: cross-repo soak-actuation court. Real durable runs on `Store.Dets`
  (multi-step plan -> checkpoints -> signals -> completion) with kill/reopen cycles,
  then every cycle's standing ledger is exported as process evidence and admitted
  through the REAL ex4pm pipeline:

    * `LedgerOCEL.events/3` -> `AshPPlan.ProcessEvidence.AshEx4pm.envelope/2`
      -> real `Ex4pm.OCEL.validate_envelope/1` -> real `Ex4pm.OCEL.normalize/1`
      (normalize's reference court refuses dangling object ids, so an asserted
      `:ok` IS the zero-dangling check; re-asserted explicitly below),
    * real `AshPPlan.ProcessEvidence.AshEx4pm.ingest/2` through
      `Ex4pm.Stream.Ingest.ingest_envelope/2`,
    * the `AshPPlan.ProcessEvidence.Ex4pm` adapter's export -> parse round trip
      (`Ex4pm.EventLog` -> OCEL 2.0 JSON -> real reader).

  Refusal non-vacuity: each envelope-refusal class is exercised by actually
  deleting the field from a real envelope and asserting the real typed
  `Ex4pm.Refusal` codes come back (`missing_envelope_schema`, `missing_envelope_producer`,
  `missing_envelope_sequence`, `missing_envelope_events`). A gate that never refuses
  carries no bits.

  Chicago-school: real DETS file, real engine, real kill, real ex4pm. No mocks.

  `SOAK_SECONDS` env gate (default off): when set, the main test loops cycles for
  that many wall-clock seconds instead of the 3-cycle default, so the same file
  doubles as a soak without slowing normal runs.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Engine, LedgerOCEL}
  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.Test.Effects

  Code.require_file("lane_b_fixture.exs", Path.join(__DIR__, "../durable"))

  @default_cycles 3
  @runs_per_cycle 8
  @soak_seconds (case System.get_env("SOAK_SECONDS") do
                   nil -> 0
                   "" -> 0
                   v -> String.to_integer(v)
                 end)
  @cycle_budget_ms 30_000

  @tag :fleet_soak
  @tag timeout: 1_800_000
  test "dets kill/reopen cycles admit their standing ledger through the real ex4pm pipeline" do
    Process.flag(:trap_exit, true)
    AshPPlan.Durable.LaneBFx.install_adapter!()
    assert AshPPlan.ProcessEvidence.Ex4pm.available?(), "ex4pm must be present for this court"
    assert AshPPlan.ProcessEvidence.AshEx4pm.available?()

    path =
      Path.join(
        System.tmp_dir!(),
        "ash_pplan_fleet_soak_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}.dets"
      )

    on_exit(fn -> File.rm(path) end)

    deadline =
      if @soak_seconds > 0,
        do: System.monotonic_time(:millisecond) + @soak_seconds * 1_000,
        else: nil

    # refusal non-vacuity ledger, filled once on cycle 1's real envelope
    refusals = :ets.new(:fleet_soak_refusals, [:set, :public])

    t0 = System.monotonic_time(:millisecond)
    cycles = loop_cycles(path, deadline, refusals, 1)

    total = System.monotonic_time(:millisecond) - t0
    assert cycles >= 1, "no cycle ran"
    IO.puts("[fleet_soak] #{cycles} cycles in #{total}ms total")

    classes =
      refusals |> :ets.tab2list() |> Enum.map(fn {c, _} -> c end) |> Enum.sort() |> Enum.uniq()

    expected =
      Enum.sort([
        :missing_envelope_events,
        :missing_envelope_producer,
        :missing_envelope_schema,
        :missing_envelope_sequence
      ])

    assert classes == expected,
           "refusal non-vacuity incomplete: #{inspect(classes)}"

    :ets.delete(refusals)
  end

  # Loop bounded by the soak deadline (SOAK_SECONDS set) or @default_cycles (default gate).
  defp loop_cycles(path, deadline, refusals, cycle) when is_integer(deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      cycle - 1
    else
      run_and_log(path, cycle, refusals)
      loop_cycles(path, deadline, refusals, cycle + 1)
    end
  end

  defp loop_cycles(_path, nil, _refusals, cycle) when cycle > @default_cycles, do: cycle - 1

  defp loop_cycles(path, nil, refusals, cycle) do
    run_and_log(path, cycle, refusals)
    loop_cycles(path, nil, refusals, cycle + 1)
  end

  defp run_and_log(path, cycle, refusals) do
    {us, verdict} = :timer.tc(fn -> run_cycle(path, cycle, refusals) end)
    assert div(us, 1000) < @cycle_budget_ms, "cycle #{cycle} over #{@cycle_budget_ms}ms budget"
    IO.puts("[fleet_soak] cycle #{cycle}: #{verdict}")
  end

  # -- one cycle --------------------------------------------------------------------------------

  defp run_cycle(path, cycle, refusals) do
    :rand.seed(:exsss, {41, cycle, 2026})

    {:ok, s} = Dets.start_link(path: path)
    flush_exit()

    fx = :"fleet_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)

    acks = String.to_atom("fleet_acks_#{System.unique_integer([:positive])}")
    acks = :ets.new(acks, [:set, :public, :named_table])

    writer =
      Task.async(fn ->
        try do
          write_workload(s, fx, cycle, acks)
          :done
        catch
          # store died mid-write: the tolerated shape. Everything acked BEFORE the exit is
          # durable and is verified against the reopened file below.
          :exit, _reason -> :crashed
        end
      end)

    # Wait for the writer's FIRST durable ack before killing: the old blind
    # `Process.sleep(25 + rand(800))` raced a cold-BEAM Engine.start (which can
    # exceed even the 25ms floor), killing the store before anything was acked
    # and tripping the `writer acked nothing` assertion. Event-driven instead:
    # poll the acks table (the same visibility verify_acked/3 reads) for the
    # first acked seq, bounded at 2s. Random-kill jitter is kept AFTER the first
    # ack so the kill still lands at a nondeterministic point mid-workload.
    wait_first_ack(acks, System.monotonic_time(:millisecond) + 2_000)

    offset = 25 + :rand.uniform(800)
    Process.sleep(offset)
    kill_store(s)

    writer_result = Task.await(writer, 25_000)
    assert writer_result in [:done, :crashed]
    :ok = flush_exit()

    {:ok, s2} = Dets.start_link(path: path)
    :ok = flush_exit()

    {intact, completed, max_seq} = verify_acked(s2, acks, cycle)

    # OCEL pipeline admission through the REAL ex4pm, for every acked run of the cycle
    ocel = admit_runs(s2, acks, refusals, cycle)

    # seq continuity across the reopen
    {:ok, probe} =
      Dets.start_run(s2, %{id: "c#{cycle}-probe", model: :soak, bindings: %{probe: cycle}})

    assert probe.seq > max_seq, "cycle #{cycle}: seq went backwards #{probe.seq} <= #{max_seq}"

    :ok = GenServer.stop(s2)
    :ok = flush_exit()
    :ets.delete(acks)

    "kill@#{offset}ms writer=#{writer_result} intact=#{intact} completed=#{completed} " <>
      "events=#{ocel.events} envelopes_ok=#{ocel.envelopes_ok} ingested=#{ocel.ingested} " <>
      "parse_ok=#{ocel.parse_ok} acked_seq=#{max_seq}"
  end

  # The real workload: 8 runs through the real Engine on Store.Dets. Every third run parks on
  # Steps.Await, is signalled and completes (checkpoint tape + park + signal path); the rest
  # complete straight through.
  defp write_workload(s, fx, cycle, acks) do
    opts = [store_module: Dets]

    for j <- 1..@runs_per_cycle do
      id = "c#{cycle}-r#{j}"

      attrs =
        if rem(j, 3) == 0,
          do: AshPPlan.Durable.LaneBFx.attrs(id, fx, kinds: %{integrate: :await}),
          else: AshPPlan.Durable.LaneBFx.attrs(id, fx, [])

      {:ok, rec} = Engine.start(s, attrs, opts)
      ack_run(acks, id, rec.seq, :pending)

      if rem(j, 3) == 0 do
        assert {:parked, :waiting} = Engine.attempt(s, id, opts)
        ack_run(acks, id, nil, :waiting)

        {:ok, sig} = Engine.signal(s, id, "go", {:cycle, cycle, j})
        bump_seq(acks, sig.seq)

        assert {:completed, _} = Engine.attempt(s, id, opts)
        ack_run(acks, id, nil, :completed)
      else
        assert {:completed, _} = Engine.attempt(s, id, opts)
        ack_run(acks, id, nil, :completed)
      end
    end

    :ok
  end

  # Poll until the writer has acked its first run (max_seq > 0 in the acks
  # table), or flunk at the deadline. 25ms poll interval.
  defp wait_first_ack(acks, deadline) do
    case :ets.lookup(acks, :max_seq) do
      [{:max_seq, n}] when n > 0 ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("writer never acked its first run within 2s deadline")
        end

        Process.sleep(25)
        wait_first_ack(acks, deadline)
    end
  end

  defp ack_run(acks, id, seq, status) do
    cur =
      case :ets.lookup(acks, {:run, id}) do
        [{{:run, ^id}, m}] -> m
        [] -> %{seq: nil, status: :pending}
      end

    :ets.insert(acks, {{:run, id}, %{seq: seq || cur.seq, status: status}})
    if seq, do: bump_seq(acks, seq)
    :ok
  end

  defp bump_seq(acks, seq) do
    prev =
      case :ets.lookup(acks, :max_seq) do
        [{:max_seq, n}] -> n
        [] -> 0
      end

    if seq > prev, do: :ets.insert(acks, {:max_seq, seq})
    :ok
  end

  # Forward-only across kill/reopen: every acked run exists with its acked seq; a run may be
  # durably AHEAD of the last ack (kill landed after the store synced a completion), never behind.
  defp verify_acked(s2, acks, cycle) do
    runs = runs_from(acks)
    assert map_size(runs) > 0, "cycle #{cycle}: writer acked nothing"

    max_seq =
      case :ets.lookup(acks, :max_seq) do
        [{:max_seq, n}] -> n
        [] -> 0
      end

    {intact, completed} =
      Enum.reduce(runs, {0, 0}, fn {id, m}, {i, c} ->
        run = Dets.get_run(s2, id)
        assert run, "cycle #{cycle}: ACKED run #{id} LOST across kill/reopen"
        assert run.seq == m.seq, "cycle #{cycle}: run #{id} seq #{run.seq} != acked #{m.seq}"

        cond do
          run.status == :completed ->
            assert m.status != :failed, "cycle #{cycle}: run #{id} regressed"
            {i + 1, c + 1}

          m.status == :completed ->
            flunk("cycle #{cycle}: acked-completed run #{id} is #{inspect(run.status)}")

          true ->
            assert run.status in [:pending, :waiting],
                   "cycle #{cycle}: run #{id} invalid parked state #{inspect(run.status)}"

            {i + 1, c}
        end
      end)

    {intact, completed, max_seq}
  end

  # -- real ex4pm admission ---------------------------------------------------------------------

  defmodule Pipeline do
    @moduledoc false
    alias AshPPlan.ProcessEvidence.AshEx4pm
    alias AshPPlan.ProcessEvidence.Ex4pm, as: PEx4pm
    alias AshPPlan.Reactor.Durable.LedgerOCEL
    alias AshPPlan.Reactor.Durable.Store.Dets

    @doc "Admit one run's standing ledger through the real ex4pm pipeline."
    def admit(store, run_id, refusals, cycle) do
      {:ok, events} = LedgerOCEL.events(store, run_id, store_module: Dets)
      assert events != []

      # wire envelope (ash_ex4pm/1) built from the REAL ledger events
      envelope = AshEx4pm.envelope(events)
      assert envelope["schema"] == "ash_ex4pm/1"
      assert is_integer(envelope["sequence"])

      # real gate
      assert {:ok, validated} = Ex4pm.OCEL.validate_envelope(envelope)
      assert validated.sequence == envelope["sequence"]

      # real court: normalize (its reference check refuses dangling object ids)
      assert {:ok, log} =
               Ex4pm.OCEL.normalize(%{
                 events: validated.events,
                 objects: validated.objects,
                 object_relationships: validated.object_relationships
               })

      assert log.metadata.event_count == length(events)

      # explicit zero-dangling assertion on the normalized log
      dangling =
        log.events
        |> Enum.flat_map(fn e -> Enum.map(e.relationships, & &1.object_id) end)
        |> Enum.uniq()
        |> Enum.reject(&Map.has_key?(log.objects, &1))

      assert dangling == [], "run #{run_id}: dangling object refs #{inspect(dangling)}"

      # real ingest through Ex4pm.Stream.Ingest (no store/miner processes -> pure pipeline)
      assert {:ok, %{status: :ingested, event_count: n}} =
               AshEx4pm.ingest(events, ingest_opts: [store: nil, miner: nil])

      assert n == length(events)

      # ProcessEvidence.Ex4pm adapter round trip: EventLog -> OCEL2 JSON -> real reader
      assert {:ok, json} = PEx4pm.export(events, :ocel2_json)
      assert {:ok, log2} = PEx4pm.parse(json)
      assert length(log2.events) == length(events)
      assert map_size(log2.objects) == map_size(log.objects)

      # refusal non-vacuity: delete one field per class from the REAL envelope (cycle 1 only)
      if cycle == 1 do
        for {field, code} <- [
              {"schema", :missing_envelope_schema},
              {"producer", :missing_envelope_producer},
              {"sequence", :missing_envelope_sequence},
              {"events", :missing_envelope_events}
            ] do
          assert {:error, %Ex4pm.Refusal{code: ^code}} =
                   Ex4pm.OCEL.validate_envelope(Map.delete(envelope, field))

          :ets.insert(refusals, {code, true})
        end
      end

      %{events: length(events), envelopes_ok: 1, ingested: 1, parse_ok: 1}
    end
  end

  defp admit_runs(store, acks, refusals, cycle) do
    acks
    |> runs_from()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&Pipeline.admit(store, &1, refusals, cycle))
    |> Enum.reduce(%{events: 0, envelopes_ok: 0, ingested: 0, parse_ok: 0}, fn m, acc ->
      %{
        events: acc.events + m.events,
        envelopes_ok: acc.envelopes_ok + m.envelopes_ok,
        ingested: acc.ingested + m.ingested,
        parse_ok: acc.parse_ok + m.parse_ok
      }
    end)
  end

  defp runs_from(acks) do
    acks
    |> :ets.tab2list()
    |> Enum.filter(fn
      {{:run, _}, _} -> true
      _ -> false
    end)
    |> Map.new(fn {{:run, id}, m} -> {id, m} end)
  end

  # -- plumbing ---------------------------------------------------------------------------------

  defp kill_store(s) do
    pid =
      case s do
        pid when is_pid(pid) -> pid
        name when is_atom(name) -> Process.whereis(name)
      end

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

    receive do
      {:EXIT, ^pid, _} -> :ok
    after
      0 -> :ok
    end

    :ok
  end

  defp flush_exit do
    receive do
      {:EXIT, _pid, _reason} -> flush_exit()
    after
      0 -> :ok
    end
  end
end
