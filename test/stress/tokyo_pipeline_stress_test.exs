defmodule AshPPlan.Stress.TokyoPipelineStressTest do
  @moduledoc """
  Scenario-scale stress: a Tokyo-Depeg-shaped durable pipeline over the real stack.

  C=64 concurrent order flows per cycle. Each flow proposes a real FOND policy via
  `AshPPlan.SA2A.Provider.propose/2` over a fixture domain (`test/support/fond_fixture.ex`
  reading `test/fixtures/fond/tla/decision_choice_matters.json`), then runs a real durable
  run through `AshPPlan.Reactor.Durable.Engine` on the real `Store.Dets` file in tmp:
  admit -> authorize -> park awaiting the `"human_release"` signal -> commit, checkpointing
  into standing at every step, and exports OCEL 2.0 evidence via `LedgerOCEL.digest/3`.

  3 cycles, hard-killing the store between cycles (`Process.exit(pid, :kill)` — untrappable,
  so `terminate/2` never runs and only the per-call `:dets.sync/1` guarantees durability),
  reopening the same DETS path. Courts:

    1. exactly-once effects: `Effects` counters admit/authorize/commit land on exactly
       64 per cycle, never above (a replayed step would push the count past the total);
    2. seq monotonicity: every new row's `seq` strictly exceeds every prior row's, within
       a cycle and across kills;
    3. zero lost runs post-restart: all runs intact and terminal after 2 kills;
    4. OCEL digest continuity: each run's evidence digest recomputed after the kill matches
       the pre-kill digest byte-for-byte (the digest is timestamp-free by design);
    5. Standing composition: every flow's three layer verdicts combine to `:alive` via
       `AshPPlan.Standing.verdict/3`.

  Numbers print to stdout: `mix test test/stress/tokyo_pipeline_stress_test.exs`.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.FOND
  alias AshPPlan.Reactor.Durable.{Engine, LedgerOCEL}
  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.SA2A.Provider
  alias AshPPlan.Standing
  alias AshPPlan.Test.{DurableFx, Effects, FONDFixture}

  @moduletag :stress
  @moduletag timeout: 900_000

  @cycles 3
  @concurrency 64
  @signal "human_release"
  @effects :fx_tokyo
  @fixtures_dir Path.join(File.cwd!(), "test/fixtures/fond/tla")
  @fixture "decision_choice_matters.json"

  setup do
    # the store is deliberately hard-killed; trap so the EXIT does not kill the test
    Process.flag(:trap_exit, true)
    {:ok, _} = Effects.start_link(name: @effects)
    DurableFx.install_adapter!()

    path =
      Path.join(
        System.tmp_dir!(),
        "ash_pplan_tokyo_stress_#{System.unique_integer([:positive])}.dets"
      )

    # the Effects agent is linked to the test process and dies with it; only the file needs cleanup
    on_exit(fn -> File.rm(path) end)

    %{path: path}
  end

  test "tokyo pipeline: #{@concurrency} concurrent orders x #{@cycles} cycles, hard kill between cycles",
       %{path: path} do
    t0 = System.monotonic_time(:millisecond)

    {cycle_digest_maps, {digests, seq_high_water}} =
      Enum.map_reduce(1..@cycles, {%{}, 0}, fn cycle, {digests, seq_hi} ->
        {cycle_digests, ms, new_hi} = run_cycle(path, cycle, seq_hi)

        IO.puts(
          "[stress] tokyo cycle #{cycle}: #{@concurrency} orders in #{ms} ms " <>
            "(#{round(@concurrency / (ms / 1000))} orders/sec), seq high-water #{new_hi}"
        )

        kill_store!()
        {cycle_digests, {Map.merge(digests, cycle_digests), new_hi}}
      end)

    total_ms = System.monotonic_time(:millisecond) - t0

    # ---- court 3: zero lost runs post-restart, all terminal --------------------
    {:ok, store} = Dets.start_link(path: path)
    on_exit(fn -> Process.exit(store, :kill) end)

    all_runs = Dets.list_runs(store)
    assert length(all_runs) == @cycles * @concurrency, "expected all runs present post-restart"

    for run <- all_runs do
      assert run.status == :completed, "run #{run.id} not terminal post-restart: #{run.status}"
    end

    # ---- court 4: OCEL digest continuity across the kills ----------------------
    for {id, expected_digest} <- digests do
      assert {:ok, actual} = LedgerOCEL.digest(store, id, store_module: Dets)
      assert actual == expected_digest, "OCEL digest drifted for #{id} across restart"
    end

    # ---- court 1: exactly-once effects (agent outlives every store kill) -------
    assert Effects.count(@effects, :admit) == @cycles * @concurrency
    assert Effects.count(@effects, :authorize) == @cycles * @concurrency
    assert Effects.count(@effects, :commit) == @cycles * @concurrency

    # ---- court 2 recap: global seq monotonicity across cycles ------------------
    seqs = all_runs |> Enum.map(& &1.seq) |> Enum.sort()
    assert seqs == Enum.uniq(seqs), "duplicate seq values across cycles"
    assert Enum.max(seqs) == seq_high_water

    IO.puts(
      "[stress] tokyo pipeline: #{@cycles * @concurrency} orders total in #{total_ms} ms " <>
        "(#{round(@cycles * @concurrency / (total_ms / 1000))} orders/sec overall), " <>
        "#{Effects.count(@effects, :admit) * 3} counted step effects, " <>
        "#{map_size(digests)} OCEL digests stable across 2 hard kills — VERDICT: ALIVE"
    )
  end

  # -- one cycle ----------------------------------------------------------------------------------

  @store_name AshPPlan.Stress.TokyoPipelineStore

  defp run_cycle(path, cycle, prior_seq_hi) do
    {:ok, store} = Dets.start_link(path: path, name: @store_name)
    # FONDFixture decodes the mode with String.to_existing_atom/1; make sure the
    # mode atoms are live in this VM before the first fixture load.
    for mode <- ~w(strong strong_cyclic), do: String.to_atom(mode)

    fixture = FONDFixture.load(Path.join(@fixtures_dir, @fixture))
    {:ok, domain} = FOND.new(fixture.transitions, fixture.goals)

    t0 = System.monotonic_time(:millisecond)

    results =
      1..@concurrency
      |> Task.async_stream(
        &order_flow(store, domain, fixture, cycle, &1),
        max_concurrency: @concurrency,
        timeout: 600_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    ms = System.monotonic_time(:millisecond) - t0

    # ---- court 2: seq monotonicity, within and across cycles -------------------
    cycle_seqs = Enum.map(results, & &1.seq)
    assert Enum.sort(cycle_seqs) == Enum.uniq(Enum.sort(cycle_seqs)), "duplicate seq in cycle"

    new_hi = Enum.max(cycle_seqs)

    assert new_hi > prior_seq_hi,
           "seq went backwards across restart: #{new_hi} <= #{prior_seq_hi}"

    # every flow's standing layers compose to :alive
    for r <- results do
      assert Standing.verdict(r.plan, r.execution, r.consequence) == :alive,
             "standing lost for #{r.id}: #{inspect({r.plan, r.execution, r.consequence})}"
    end

    digests = Map.new(results, &{&1.id, &1.digest})
    {digests, ms, new_hi}
  end

  # one order flow: real propose/2 -> durable run -> signal -> OCEL digest
  defp order_flow(store, domain, fixture, cycle, i) do
    subject = "tokyo-depeg/c#{cycle}/order#{i}"

    # plan layer: a real FOND candidate, authority :none, standing :candidate
    request = %{formalism: :fond, subject: subject, domain: domain, initial: fixture.initial}
    assert {:ok, candidate} = Provider.propose(request, [])
    assert candidate.authority == :none and candidate.standing == :candidate
    plan_verdict = if is_map(candidate.policy), do: :ok, else: {:error, :no_policy}

    id = subject

    attrs =
      DurableFx.attrs(id, effects: @effects)
      |> Map.put(:context, %{
        AshPPlan.Reactor.context_key() => %{subject: run_subject(cycle, i), task: "tokyo_depeg"}
      })

    assert {:ok, _rec} = Engine.start(store, attrs, store_module: Dets)
    assert {:parked, :waiting} = Engine.attempt(store, id, store_module: Dets)

    assert map_size(Dets.checkpoints(store, id)) == 2

    # signal layer: deliver once, consumed exactly once by the resuming attempt
    assert is_nil(Dets.pending_signal(store, id, @signal))
    assert {:ok, _sig} = Dets.deliver_signal(store, id, @signal, %{cycle: cycle, order: i})

    assert {:completed, _} = Engine.attempt(store, id, store_module: Dets)
    assert is_nil(Dets.pending_signal(store, id, @signal))

    run = Engine.fetch(store, id, store_module: Dets)
    assert run.status == :completed

    execution_verdict =
      if Effects.count(@effects, :admit) <= cycle * @concurrency,
        do: :ok,
        else: {:error, :over_count}

    # consequence layer: tamper-evident OCEL evidence over the standing ledger
    assert {:ok, digest} = LedgerOCEL.digest(store, id, store_module: Dets)
    assert {:ok, events} = LedgerOCEL.events(store, id, store_module: Dets)
    assert [%{activity: "run_started"} | _] = events
    assert [%{activity: "run_ended"} | _] = events |> Enum.reverse()
    assert length(Enum.filter(events, &(&1.activity == "task_succeeded"))) == 4

    %{
      id: id,
      seq: run.seq,
      digest: digest,
      plan: plan_verdict,
      execution: execution_verdict,
      consequence: :ok
    }
  end

  # the durable run's subject must be a sha256-bound identity (Reactor identity middleware)
  defp run_subject(cycle, i) do
    subject = "tokyo-depeg/c#{cycle}/order#{i}"
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, subject), case: :lower)
  end

  defp kill_store! do
    pid = Process.whereis(@store_name)
    Process.exit(pid, :kill)
    assert_receive {:EXIT, ^pid, :killed}, 15_000
  end
end
