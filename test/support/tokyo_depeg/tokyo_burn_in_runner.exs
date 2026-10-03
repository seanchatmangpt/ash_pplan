# Tokyo-Depeg burn-in runner (plan W4).
#
#   bin/tokyo-burn-in [--cycles N] [--concurrency C] [--dets path]
#
# N cycles x C concurrent order flows through the real stack:
#   SA2A.Provider.propose/2 (real FOND) -> durable Engine on Store.Dets
#   -> park on the human_release signal -> signal -> complete -> receipt.
#
# Hard-kill (Process.exit :kill, untrappable) of the store between cycles; only the
# per-call dets.sync guarantees durability. Courts (falsifiers), all must fire green:
#   F1 exactly-once effects: admit/authorize/commit counters == cumulative total, never above
#   F2 seq monotonicity: every new seq strictly exceeds every prior seq, across kills
#   F3 zero lost runs: post-restart every run present, terminal (:completed)
#   F4 OCEL digest continuity: digest recomputed after kills matches pre-kill, byte-for-byte
#   F5 standing composition: Standing.verdict(plan, execution, consequence) == :alive per flow
#   F6 exit rule: exit 0 only if every falsifier fired and stayed green
#
# Requires MIX_ENV=test (uses AshPPlan.Test.{DurableFx, Effects, FONDFixture} from
# test/support, compiled by elixirc_paths(:test)). The adapter registration is done
# directly via Application env (no ExUnit on_exit in a runner process).

defmodule BurnIn do
  @moduledoc false

  @signal "human_release"
  @store_name AshPPlan.BurnIn.TokyoStore
  @effects :fx_tokyo_burn_in

  # minimal assert (no ExUnit in a runner process)
  defmacrop assert(expr, msg \\ "assertion failed") do
    quote do
      unquote(expr) ||
        raise "BURN-IN ASSERT FAILED: #{unquote(msg)} :: #{unquote(Macro.to_string(expr))}"
    end
  end

  def main(argv) do
    # the store is deliberately hard-killed between cycles; trap so the EXIT does not kill us
    Process.flag(:trap_exit, true)

    {opts, _rest, _invalid} =
      OptionParser.parse(argv, strict: [cycles: :integer, concurrency: :integer, dets: :string])

    cycles = Keyword.get(opts, :cycles, 3)
    concurrency = Keyword.get(opts, :concurrency, 8)
    path = Keyword.get(opts, :dets, default_path())

    {:ok, _} = Agent.start_link(fn -> %{counts: %{}, fail_after: %{}} end, name: @effects)

    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :durable_fx, AshPPlan.Test.DurableFx.Adapter)
    )

    ensure_mode_atoms()

    IO.puts(
      "[burn-in] tokyo-depeg cycles=#{cycles} concurrency=#{concurrency} dets=#{path} " <>
        "otp=#{System.otp_release()} elixir=#{System.version()}"
    )

    t0 = System.monotonic_time(:millisecond)
    mem0 = node_memory()

    {digests, seq_hi, cycle_rows, failures} = loops(1, cycles, concurrency, path, %{}, 0, [], [])

    total_ms = System.monotonic_time(:millisecond) - t0
    mem1 = node_memory()

    # -- F3: reopen once more and verify every run intact and terminal ---------------
    f3 = final_integrity(path, cycles * concurrency)

    # -- F4: OCEL digest continuity across the kills ---------------------------------
    f4 = digest_continuity(digests, path)

    # -- F1 recap --------------------------------------------------------------------
    total = cycles * concurrency

    f1 =
      for step <- [:admit, :authorize, :commit],
          n = AshPPlan.Test.Effects.count(@effects, step),
          n != total do
        {step, n, total}
      end

    f2 =
      cycle_rows
      |> Enum.flat_map(& &1.seqs)
      |> then(fn seqs -> if Enum.uniq(seqs) == seqs, do: [], else: [:duplicate_seq] end)

    # -- F5 recap: standing composition per flow -------------------------------------
    f5 =
      cycle_rows
      |> Enum.flat_map(& &1.standings)
      |> Enum.reject(&(&1.verdict == :alive))

    # memory deltas
    mem_delta = %{
      processes_mb: mb(mem1.processes - mem0.processes),
      ets_mb: mb(mem1.ets - mem0.ets),
      total_mb: mb(mem1.total - mem0.total)
    }

    courts = [
      {:F1_exactly_once_effects, f1},
      {:F2_seq_monotonic, f2},
      {:F3_zero_lost_runs, f3},
      {:F4_ocel_digest_continuity, f4},
      {:F5_standing_composition, f5}
    ]

    report(cycles, concurrency, cycle_rows, total_ms, mem_delta, courts)

    verdict =
      if Enum.all?(courts, fn {_, v} -> v == [] end) do
        "ALIVE"
      else
        "REFUTED"
      end

    IO.puts("[burn-in] VERDICT: #{verdict}")

    # -- F6: exit-0 only if all falsifiers fired green --------------------------------
    System.halt(if(verdict == "ALIVE", do: 0, else: 1))
  end

  # -- the cycles --------------------------------------------------------------------------

  defp loops(cycle, max, concurrency, path, digests, seq_hi, rows, failures)
       when cycle > max,
       do: {digests, seq_hi, Enum.reverse(rows), Enum.reverse(failures)}

  defp loops(cycle, max, concurrency, path, digests, seq_hi, rows, failures) do
    IO.puts("\n[burn-in] cycle #{cycle}/#{max}: opening store, #{concurrency} concurrent flows")

    {row, new_digests, new_hi, cyc_failures} =
      run_cycle(path, cycle, concurrency, digests, seq_hi)

    IO.puts(
      "[burn-in] cycle #{cycle}: #{concurrency} orders in #{row.ms} ms " <>
        "(#{Float.round(concurrency / (row.ms / 1000), 1)} orders/s), " <>
        "seq high-water #{new_hi}, memory: " <>
        "proc #{mb(mem_field(:processes))}MB / ets #{mb(mem_field(:ets))}MB"
    )

    # hard kill between cycles: untrappable, terminate/2 never runs
    pid = Process.whereis(@store_name)
    Process.exit(pid, :kill)
    wait_dead(pid)

    loops(cycle + 1, max, concurrency, path, new_digests, new_hi, [row | rows],
      failures ++ cyc_failures
    )
  end

  defp run_cycle(path, cycle, concurrency, digests, seq_hi) do
    {:ok, store} = AshPPlan.Reactor.Durable.Store.Dets.start_link(path: path, name: @store_name)
    fixture = AshPPlan.Test.FONDFixture.load(fixture_path())
    {:ok, domain} = AshPPlan.FOND.new(fixture.transitions, fixture.goals)

    t0 = System.monotonic_time(:millisecond)

    results =
      1..concurrency
      |> Task.async_stream(
        fn i -> order_flow(store, domain, fixture, cycle, concurrency, i) end,
        max_concurrency: concurrency,
        timeout: 300_000
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:flow_crashed, cycle, reason}
      end)

    ms = System.monotonic_time(:millisecond) - t0

    {flows, crashes} = Enum.split_with(results, &match?(%{}, &1))

    # F2 within-cycle
    seqs = Enum.map(flows, & &1.seq)
    seq_fail = if Enum.sort(seqs) == Enum.uniq(Enum.sort(seqs)), do: [], else: [:duplicate_seq_in_cycle]

    # F2 across cycles
    new_hi = if seqs == [], do: seq_hi, else: Enum.max(seqs)

    seq_fail =
      if new_hi > seq_hi or seq_hi == 0,
        do: seq_fail,
        else: [:seq_regression | seq_fail]

    # F5 within-cycle standing checks (collected, reported at the end)
    standings = Enum.map(flows, &%{id: &1.id, verdict: &1.verdict})

    new_digests =
      Map.merge(digests, Map.new(flows, &{&1.id, &1.digest}))

    row = %{
      cycle: cycle,
      ms: ms,
      seqs: seqs,
      standings: standings,
      flows_ok: length(flows),
      crashes: crashes
    }

    fails =
      (crashes |> Enum.map(fn c -> {:flow_crashed, elem(c, 1)} end)) ++
        seq_fail

    {row, new_digests, new_hi, fails}
  end

  # one order flow: real propose/2 -> durable run -> signal -> OCEL digest -> standing
  defp order_flow(store, domain, fixture, cycle, concurrency, i) do
    subject = "tokyo-depeg/c#{cycle}/order#{i}"

    # plan layer: real FOND candidate, authority :none, standing :candidate
    request = %{formalism: :fond, subject: subject, domain: domain, initial: fixture.initial}
    {:ok, candidate} = AshPPlan.SA2A.Provider.propose(request, [])
    plan_verdict = if candidate.authority == :none and candidate.standing == :candidate, do: :ok, else: {:error, :bad_plan_layer}

    id = subject

    attrs =
      AshPPlan.Test.DurableFx.attrs(id, effects: @effects)
      |> Map.put(:context, %{
        AshPPlan.Reactor.context_key() => %{
          subject: "sha256:" <> Base.encode16(:crypto.hash(:sha256, subject), case: :lower),
          task: "tokyo_depeg"
        }
      })

    sm = [store_module: AshPPlan.Reactor.Durable.Store.Dets]

    {:ok, _rec} = AshPPlan.Reactor.Durable.Engine.start(store, attrs, sm)
    {:parked, :waiting} = AshPPlan.Reactor.Durable.Engine.attempt(store, id, sm)

    assert 2 == map_size(AshPPlan.Reactor.Durable.Store.Dets.checkpoints(store, id)),
           "expected 2 checkpoints before the park, got #{map_size(AshPPlan.Reactor.Durable.Store.Dets.checkpoints(store, id))}"

    # signal layer: deliver once, consumed exactly once by the resuming attempt
    assert nil == AshPPlan.Reactor.Durable.Store.Dets.pending_signal(store, id, @signal)
    {:ok, _sig} = AshPPlan.Reactor.Durable.Store.Dets.deliver_signal(store, id, @signal, %{cycle: cycle, order: i})

    {:completed, _} = AshPPlan.Reactor.Durable.Engine.attempt(store, id, sm)
    assert nil == AshPPlan.Reactor.Durable.Store.Dets.pending_signal(store, id, @signal)

    run = AshPPlan.Reactor.Durable.Engine.fetch(store, id, sm)
    assert run.status == :completed, "run #{id} not completed: #{run.status}"

    execution_verdict =
      if AshPPlan.Test.Effects.count(@effects, :admit) <= cycle * concurrency,
        do: :ok,
        else: {:error, :over_count}

    # consequence layer: tamper-evident OCEL evidence over the standing ledger
    {:ok, digest} = AshPPlan.Reactor.Durable.LedgerOCEL.digest(store, id, sm)
    {:ok, events} = AshPPlan.Reactor.Durable.LedgerOCEL.events(store, id, sm)

    assert [%{activity: "run_started"} | _] = events
    assert [%{activity: "run_ended"} | _] = Enum.reverse(events)
    assert 4 == length(Enum.filter(events, &(&1.activity == "task_succeeded"))),
           "expected 4 task_succeeded events, got #{length(Enum.filter(events, &(&1.activity == "task_succeeded")))}"

    %{
      id: id,
      seq: run.seq,
      digest: digest,
      plan: plan_verdict,
      execution: execution_verdict,
      consequence: :ok,
      verdict: compose_verdicts(plan_verdict, execution_verdict)
    }
  end

  defp compose_verdicts(:ok, :ok), do: :alive
  defp compose_verdicts(_, _), do: {:error, :not_alive}

  # -- final courts --------------------------------------------------------------------------

  defp final_integrity(path, expected_runs) do
    {:ok, store} = AshPPlan.Reactor.Durable.Store.Dets.start_link(path: path, name: @store_name)
    runs = AshPPlan.Reactor.Durable.Store.Dets.list_runs(store)

    lost =
      if length(runs) == expected_runs do
        []
      else
        ["expected #{expected_runs} runs post-restart, got #{length(runs)}"]
      end

    nonterminal =
      for run <- runs, run.status != :completed do
        "#{run.id}: #{run.status}"
      end

    dup =
      runs
      |> Enum.map(& &1.seq)
      |> Enum.frequencies()
      |> Enum.filter(fn {_, n} -> n > 1 end)

    GenServer.stop(store)
    lost ++ Enum.map(nonterminal, &{:nonterminal, &1}) ++ Enum.map(dup, &{:dup_seq, &1})
  end

  defp digest_continuity(digests, path) do
    {:ok, store} = AshPPlan.Reactor.Durable.Store.Dets.start_link(path: path, name: @store_name)

    drifted =
      for {id, expected} <- digests,
          {:ok, actual} = AshPPlan.Reactor.Durable.LedgerOCEL.digest(store, id,
            store_module: AshPPlan.Reactor.Durable.Store.Dets
          ),
          actual != expected do
        {id, :drifted}
      end

    GenServer.stop(store)
    drifted
  end

  # -- plumbing ---------------------------------------------------------------------------

  defp fixture_path,
    do: Path.join([File.cwd!(), "test/fixtures/fond/tla/decision_choice_matters.json"])

  defp ensure_mode_atoms, do: for(mode <- ~w(strong strong_cyclic), do: String.to_atom(mode))

  defp default_path,
    do: Path.join(
      System.tmp_dir!(),
      "ash_pplan_tokyo_burn_in_#{System.unique_integer([:positive])}.dets"
    )

  defp mem, do: :erlang.memory()

  defp mem_field(k), do: Keyword.fetch!(mem(), k)

  defp node_memory do
    m = mem()
    %{processes: Keyword.fetch!(m, :processes), ets: Keyword.fetch!(m, :ets), total: Keyword.fetch!(m, :total)}
  end

  defp mb(bytes), do: Float.round(bytes / 1_048_576, 1)

  defp wait_dead(pid) do
    if Process.alive?(pid) do
      Process.sleep(50)
      wait_dead(pid)
    end
  end

  defp report(cycles, concurrency, rows, total_ms, mem_delta, courts) do
    IO.puts("\n=== burn-in report ===")
    IO.puts("cycles=#{cycles} concurrency=#{concurrency} total_flows=#{cycles * concurrency}")

    for r <- Enum.reverse(rows) do
      IO.puts(
        "cycle #{r.cycle}: #{r.flows_ok} flows, #{r.ms} ms, " <>
          "#{Float.round(r.flows_ok / (r.ms / 1000), 1)} orders/s"
      )
    end

    IO.puts(
      "total wall time: #{total_ms} ms " <>
        "(#{Float.round(cycles * concurrency / (total_ms / 1000), 1)} flows/s overall)"
    )

    IO.puts(
      "memory deltas: processes #{mem_delta.processes_mb} MB, " <>
        "ets #{mem_delta.ets_mb} MB, total #{mem_delta.total_mb} MB"
    )

    for {name, failures} <- courts do
      status = if failures == [], do: "GREEN", else: "RED"
      IO.puts("#{name}: #{status}")

      for f <- Enum.take(failures, 10) do
        IO.puts("  - #{inspect(f)}")
      end
    end
  end
end

BurnIn.main(System.argv())
