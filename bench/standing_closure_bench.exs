# Standing/closure-path benchmarks: Standing.receipt/2 at evidence sizes
# 10/100/1k events, Standing.ladder/2 at rung depths 3/6/10, FOND policy
# synthesis+validation (policy_closure) at graph sizes 50/500/5000 nodes, and
# ExecutionReceipt observe + N-Triples projection (construction+validation)
# at 1k.
#
#   MIX_BUILD_ROOT=_build-errc8 MIX_ENV=test mix run bench/standing_closure_bench.exs [out.json]
#
# No Benchee (not a dependency; none added). Harness mirrors bench/hot_paths_bench.exs:
# warm-up, seven timed batches, ips / mean us / stddev / process-memory per op.

defmodule StandingClosureBench do
  @moduledoc false

  alias AshPPlan.ExecutionReceipt
  alias AshPPlan.FOND
  alias AshPPlan.FOND.Synthesis
  alias AshPPlan.Standing

  @batches 7

  # -- harness (mirrors hot_paths_bench.exs) ---------------------------------

  def measure(name, n, fun) do
    for _ <- 1..min(n, 50), do: fun.()

    {times_us, ips_list} =
      for _ <- 1..@batches do
        {us, _} = :timer.tc(fn -> for _ <- 1..n, do: fun.() end)
        {us / n, n / (us / 1_000_000)}
      end
      |> Enum.unzip()

    mean_us = Enum.sum(times_us) / @batches
    ips = Enum.sum(ips_list) / @batches

    var =
      Enum.reduce(times_us, 0, fn t, acc -> acc + (t - mean_us) * (t - mean_us) end) /
        (@batches - 1)

    stddev_us = :math.sqrt(var)
    mem = mem_per_op(fun, n)

    %{
      name: name,
      ips: Float.round(ips, 1),
      mean_us: Float.round(mean_us, 2),
      stddev_us: Float.round(stddev_us, 2),
      stddev_pct: Float.round(100 * stddev_us / mean_us, 1),
      mem_bytes_per_op: mem
    }
  end

  defp mem_per_op(fun, n) do
    parent = self()

    spawn_link(fn ->
      :erlang.garbage_collect()
      before_mem = :erlang.process_info(self(), :memory) |> elem(1)
      for _ <- 1..n, do: fun.()
      :erlang.garbage_collect()
      after_mem = :erlang.process_info(self(), :memory) |> elem(1)
      send(parent, {:mem, max(0, after_mem - before_mem)})
      Process.sleep(:infinity)
    end)

    mem =
      receive do
        {:mem, delta} -> Float.round(delta / n, 2)
      after
        120_000 -> :timeout
      end

    :erlang.garbage_collect()
    mem
  end

  # -- fixtures --------------------------------------------------------------

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)

  # A chain of `n` tasks t1..tn, each depending on its predecessor, one
  # task_succeeded event per task, providers matching the selection. This is
  # the standing_test.exs fixture shape scaled to n events, so a full run
  # exercises the plan layer, the execution layer and the sealed OCEL ledger.
  defp chain_run(n) do
    tasks =
      for i <- 1..n do
        %{id: :"t#{i}", depends_on: (i == 1 && []) || [:"t#{i - 1}"]}
      end

    model = %{tasks: tasks}
    selection = Map.new(1..n, fn i -> {"t#{i}", :"p#{i}"} end)

    events =
      for i <- 1..n do
        %AshPPlan.ProcessEvidence.Event{
          id: "run:r1/t#{i}",
          activity: "task_succeeded",
          timestamp: ~U[2026-10-01 00:00:00Z],
          objects: [{"WorkflowRun", "run:r1", "run"}],
          attributes: %{task: "t#{i}", seq: i, provider: "p#{i}", outcome: nil},
          subject_id: "subject-1"
        }
      end

    attempts = Map.new(1..n, fn i -> {:"t#{i}", 1} end)

    %{
      run_id: "r1",
      repo: "ash_pplan",
      head: @head,
      base: @base,
      events: events,
      model: model,
      selection: selection,
      fond_gates: [],
      execution: {attempts, attempts},
      consequence: [chain_complete: true],
      observation: %{tasks_completed: n}
    }
  end

  defp cmds, do: [%{cmd: "mix test", cwd: File.cwd!(), exit: 0}]

  # A FOND chain domain of n states s1..sn: one nondeterministic retry action
  # per state (outcome stays at the same state with some probability) plus a
  # deterministic advance; the last state is the only goal. This forces the
  # strong-cyclic fixpoint to do real work at every state.
  defp chain_domain(n) do
    transitions =
      Map.new(1..n, fn i ->
        s = :"s#{i}"

        if i == n do
          {s, %{}}
        else
          nxt = :"s#{i + 1}"
          {s, %{advance: [nxt], retry: [s, nxt]}}
        end
      end)

    {:ok, domain} = FOND.new(transitions, [:"s#{n}"])
    {domain, :s1}
  end

  # -- suites ----------------------------------------------------------------

  def receipt_suite do
    for n <- [10, 100, 1_000] do
      run = chain_run(n)
      opts = [replay_commands: cmds()]

      # sanity: the scaled fixture is ALIVE, not an accidental refusal path
      {:ok, receipt} = Standing.receipt(run, opts)
      %AshPPlan.Standing.Receipt{standing: %{value: value}} = receipt
      IO.puts("  [receipt n=#{n}] standing=#{value}")

      measure("standing_receipt/#{n}_events", max(1, div(2_000, n)), fn ->
        Standing.receipt(run, opts)
      end)
    end
  end

  # A run truncated so the ladder promotes exactly to rung `depth`
  # (1 OBSERVED .. 9 VERIFIED); depth 10 carries full evidence and reaches
  # VERIFIED with the complete trail.
  defp ladder_run(depth) do
    run = chain_run(10)

    run
    |> then(fn r ->
      case depth do
        # stop before DERIVED: no execution comparison
        3 -> Map.drop(r, [:execution])
        # stop before MANUFACTURED: no receipt identity
        6 -> Map.drop(r, [:run_id])
        _ -> r
      end
    end)
  end

  def ladder_suite do
    for depth <- [3, 6, 10] do
      run = ladder_run(depth)

      case Standing.ladder(run, replay_commands: cmds()) do
        {:ok, %{state: state, index: idx}} ->
          IO.puts("  [ladder depth=#{depth}] state=#{state} index=#{idx}")

        {:error, e} ->
          IO.puts("  [ladder depth=#{depth}] error=#{inspect(e)}")
      end

      measure("standing_ladder/depth_#{depth}", 100, fn ->
        Standing.ladder(run, replay_commands: cmds())
      end)
    end
  end

  def policy_closure_suite do
    for n <- [50, 500, 5_000] do
      {domain, initial} = chain_domain(n)

      {:ok, policy} = Synthesis.synthesize(domain, initial, :strong_cyclic)

      case FOND.validate_policy(domain, policy, initial, :strong_cyclic) do
        {:ok, %{reachable_count: c, semantics: sem}} ->
          IO.puts(
            "  [policy_closure n=#{n}] #{sem} policy valid, reachable=#{c}, |policy|=#{map_size(policy)}"
          )

        other ->
          IO.puts("  [policy_closure n=#{n}] validate=#{inspect(other)}")
      end

      synthesize_fn = fn -> Synthesis.synthesize(domain, initial, :strong_cyclic) end
      validate_fn = fn -> FOND.validate_policy(domain, policy, initial, :strong_cyclic) end

      # synthesis is the expensive closure; validation is the cheap replay
      syn_n = if n >= 5_000, do: 1, else: max(1, div(5_000, n))
      val_n = max(1, div(50_000, n))

      syn = measure("policy_closure/synthesize_strong_cyclic/#{n}_nodes", syn_n, synthesize_fn)
      val = measure("policy_closure/validate_policy/#{n}_nodes", val_n, validate_fn)

      %{
        name: "policy_closure/#{n}_nodes",
        synthesize_us: syn.mean_us,
        synthesize_mem_bytes: syn.mem_bytes_per_op,
        validate_us: val.mean_us,
        validate_mem_bytes: val.mem_bytes_per_op
      }
    end
  end

  def execution_receipt_suite do
    # 1k ExecutionReceipt constructions + N-Triples projections
    now = DateTime.utc_now()
    started_mono = System.monotonic_time()
    result = {:ok, %{shipments: 1}}

    n = 1_000

    measure("execution_receipt/observe_and_to_rdf/1k", n, fn ->
      r = ExecutionReceipt.observe("plan:bench", "run-bench", result, now, started_mono)
      ExecutionReceipt.to_rdf(r)
    end)
  end

  def run do
    IO.puts("== Standing.receipt/2 ==")
    receipt = receipt_suite()

    IO.puts("== Standing.ladder/2 ==")
    ladder = ladder_suite()

    IO.puts("== policy closure ==")
    closure = policy_closure_suite()

    IO.puts("== ExecutionReceipt ==")
    exec = execution_receipt_suite()

    %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      otp: System.otp_release(),
      elixir: System.version(),
      receipt: receipt,
      ladder: ladder,
      policy_closure: closure,
      execution_receipt: exec
    }
  end
end

out =
  case System.argv() do
    [path | _] -> path
    _ -> nil
  end

results = StandingClosureBench.run()

if out do
  File.write!(out, Jason.encode!(results, pretty: true))
  IO.puts("wrote #{out}")
end
