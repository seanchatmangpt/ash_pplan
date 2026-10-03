# Tokyo-depeg pipeline per-stage cost baseline (BENCH lane, 2026-10-03).
#
#   MIX_BUILD_ROOT=_build-tdb-b2 MIX_ENV=test mix run bench/tokyo_stage_costs.exs [out.json]
#
# No Benchee (not a dependency; none added). Same in-script timing harness as
# bench/tdb_burn_in_bench.exs: warm-up, seven timed batches, ips + mean
# microseconds per op + stddev. Real collaborators only: the real
# Canonical/Alignment/Standing/Compiler/ProcessEvidence modules -- no mocks,
# no stubs.

defmodule TokyoStageBench do
  @moduledoc false

  @batches 7

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

    %{
      name: name,
      ips: Float.round(ips, 1),
      mean_us: Float.round(mean_us, 2),
      stddev_us: Float.round(stddev_us, 2),
      stddev_pct: Float.round(100 * stddev_us / mean_us, 1)
    }
  end

  # -- tokyo fixtures ----------------------------------------------------------

  # A realistic JSON-shaped settlement effect (stage-1 canonicalize+identity input).
  def effect(i) do
    %{
      "account" => "acct-1",
      "venue" => "NYSE",
      "settlement_id" => "settle-#{i}",
      "amount_usd" => 1_000_000.25,
      "legs" => [
        %{"side" => "buy", "qty" => 500, "px" => 2000.5},
        %{"side" => "sell", "qty" => 500, "px" => 2000.75}
      ],
      "controls" => %{"sanctions_screen" => "clear", "ecb_freeze" => false},
      "ts" => "2026-10-03T00:00:00Z"
    }
  end

  # Tokyo lifecycle trace of a given length. len 4 = exact conforming trace;
  # longer traces append off-model activity (cost > 0 is expected).
  def trace(4), do: ["RiskPreflight", "CollateralCheck", "SanctionsScreen", "Execution"]

  def trace(len) do
    base = trace(4)

    base ++
      for i <- 1..(len - 4), do: (if rem(i, 3) == 0, do: "RiskPreflight", else: "Extra_#{i}")
  end

  # -- Standing run fixture (same shape as test/standing_test.exs) --------------

  defmodule Ev do
    @moduledoc false
    defstruct [:id, :activity, :timestamp, :objects, :attributes, :subject_id]
  end

  # ProcessEvidence.Event-shaped events via the real struct
  alias AshPPlan.ProcessEvidence.Event

  def events do
    [
      %Event{
        id: "run:r1/admit",
        activity: "task_succeeded",
        timestamp: ~U[2026-10-03 00:00:00Z],
        objects: [{"WorkflowRun", "run:r1", "run"}],
        attributes: %{task: "admit", seq: 1, provider: "p1", outcome: nil},
        subject_id: "sha256:tokyo-subject"
      },
      %Event{
        id: "run:r1/pay",
        activity: "task_succeeded",
        timestamp: ~U[2026-10-03 00:00:01Z],
        objects: [{"WorkflowRun", "run:r1", "run"}],
        attributes: %{task: "pay", seq: 2, provider: "p2", outcome: "authorized"},
        subject_id: "sha256:tokyo-subject"
      },
      %Event{
        id: "run:r1/ship",
        activity: "task_succeeded",
        timestamp: ~U[2026-10-03 00:00:02Z],
        objects: [{"WorkflowRun", "run:r1", "run"}],
        attributes: %{task: "ship", seq: 3, provider: "p3", outcome: nil},
        subject_id: "sha256:tokyo-subject"
      }
    ]
  end

  def run do
    %{
      run_id: "tokyo-bench-r1",
      repo: "ash_pplan",
      head: String.duplicate("a", 40),
      base: String.duplicate("b", 40),
      events: events(),
      model: %{
        tasks: [
          %{id: :admit, depends_on: []},
          %{id: :pay, depends_on: [:admit]},
          %{id: :ship, depends_on: [:pay]}
        ]
      },
      selection: %{admit: :p1, pay: :p2, ship: :p3},
      fond_gates: [%{task: "pay", admit: ["authorized"], successors: ["ship"]}],
      execution: {%{pay: 1}, %{pay: 1}},
      consequence: [order_fulfilled: true, one_shipment: true],
      observation: %{shipments: 1}
    }
  end

  def cmds, do: [%{cmd: "mix run bench/tokyo_stage_costs.exs", cwd: File.cwd!(), exit: 0}]

  # -- 1k OCEL evidence events ---------------------------------------------------

  def ocel_events(n) do
    for i <- 1..n do
      %Event{
        id: "run:ocel/e#{i}",
        activity: "task_succeeded",
        timestamp: DateTime.add(~U[2026-10-03 00:00:00Z], i, :millisecond),
        objects: [{"WorkflowRun", "run:ocel", "run"}, {"Account", "acct-1", "about"}],
        attributes: %{
          task: "step#{rem(i, 8)}",
          seq: i,
          provider: "p#{rem(i, 3) + 1}",
          outcome: nil,
          output_digest: String.duplicate("a", 64)
        },
        subject_id: "sha256:tokyo-subject"
      }
    end
  end
end

alias AshPPlan.Compiler
alias AshPPlan.ProcessEvidence
alias AshPPlan.Standing
alias TokyoStageBench, as: B

# The shared MIX_ENV=test build root is currently blocked by a compile error in
# another lane's file (test/support/tokyo_depeg/refusals.ex: string literals in
# a typespec union). This bench runs under MIX_ENV=dev and compiles the two
# support modules it owns directly -- same source, no copies.
Code.compile_file("canonical.ex", Path.join(File.cwd!(), "test/support/tokyo_depeg"))
Code.compile_file("alignment.ex", Path.join(File.cwd!(), "test/support/tokyo_depeg"))
alias AshPPlan.Test.TokyoDepeg.Canonical
alias AshPplan.TokyoDepeg.Alignment

rows = []

# ---------------------------------------------------------------------------
# 1. canonicalize + identity (JCS canonical form + BLAKE2b-512)
effect = B.effect(1)

# sanity: identity must be deterministic
id0 = Canonical.identity(effect)
:ok = if Canonical.identity(effect) == id0, do: :ok, else: raise("nondeterministic identity")

rows = [
  B.measure("stage1_canonical_identity", 2_000, fn ->
    _id = Canonical.identity(effect)
    :ok
  end)
  | rows
]

# ---------------------------------------------------------------------------
# 2. duplicate-fence decision (Compiler.compile_spec, 200 steps sharing one IRI)
defmodule BenchNoop do
  @moduledoc false
  use Reactor.Step

  @impl true
  def run(_arguments, _context, _options), do: {:ok, :noop}
end

dup_spec = %{
  iri: "plan:tokyo_bench_dup",
  steps:
    for i <- 1..200 do
      %{
        iri: "step:dup",
        predecessors: if(i == 1, do: [], else: ["step:dup"]),
        inputs: ["in:#{i}"],
        outputs: ["out:#{i}"]
      }
    end
}

uniq_spec = %{
  iri: "plan:tokyo_bench_uniq",
  steps:
    for i <- 1..200 do
      %{
        iri: "step:#{i}",
        predecessors: if(i == 1, do: [], else: ["step:#{i - 1}"]),
        inputs: ["in:#{i}"],
        outputs: ["out:#{i}"]
      }
    end
}

handlers = Map.new(uniq_spec.steps, &{&1.iri, BenchNoop})

case Compiler.compile_spec(dup_spec, handlers) do
  {:error, %AshPPlan.Compiler.Error{reason: :duplicate_steps}} -> :ok
  other -> raise "duplicate fence did not fire: #{inspect(other, limit: 5)}"
end

{:ok, _} = Compiler.compile_spec(uniq_spec, handlers)

rows = [
  B.measure("stage2_duplicate_fence_200_dups", 500, fn ->
    {:error, %AshPPlan.Compiler.Error{reason: :duplicate_steps}} =
      Compiler.compile_spec(dup_spec, handlers)

    :ok
  end)
  | rows
]

rows = [
  B.measure("stage2_no_fence_200_unique", 500, fn ->
    {:ok, _} = Compiler.compile_spec(uniq_spec, handlers)
    :ok
  end)
  | rows
]

# ---------------------------------------------------------------------------
# 3. conformance alignment at trace lens 4 / 16 / 64 (real align/2)
{:ok, lifecycle} = Alignment.lifecycle()

rows =
  for len <- [4, 16, 64], reduce: rows do
    acc ->
      tr = B.trace(len)
      {:ok, result} = Alignment.align(lifecycle, tr)

      if not (is_integer(result.cost) and result.cost >= 0) do
        raise "bad alignment cost #{inspect(result.cost)}"
      end

      [
        B.measure("stage3_align_trace_len_#{len}", 200, fn ->
          {:ok, _} = Alignment.align(lifecycle, tr)
          :ok
        end)
        | acc
      ]
  end

# ---------------------------------------------------------------------------
# 4. Standing.verdict/3 (combine three layer verdicts) and verdicts/1 (full run)
v = Standing.verdicts(B.run())

if v.plan_correct != :ok or v.execution_correct != :ok or v.observed_consequence_correct != :ok,
  do: raise "fixture run must be fully alive: #{inspect(v)}"

rows = [
  B.measure("stage4_standing_verdict3", 200_000, fn ->
    :alive = Standing.verdict(:ok, :ok, :ok)
    :ok
  end)
  | rows
]

rows = [
  B.measure("stage4_standing_verdicts_full_run", 2_000, fn ->
    %{plan_correct: :ok, execution_correct: :ok, observed_consequence_correct: :ok} =
      Standing.verdicts(B.run())

    :ok
  end)
  | rows
]

# ---------------------------------------------------------------------------
# 5. receipt assembly (Standing.receipt/2, full five-field receipt + validation)
{:ok, receipt} = Standing.receipt(B.run(), replay_commands: B.cmds())
:ok = if receipt.standing.value == "ALIVE", do: :ok, else: raise("bad receipt standing")

rows = [
  B.measure("stage5_receipt_assembly", 500, fn ->
    {:ok, _} = Standing.receipt(B.run(), replay_commands: B.cmds())
    :ok
  end)
  | rows
]

# ---------------------------------------------------------------------------
# 6. OCEL 2.0 export + digest at 1k events
evs1k = B.ocel_events(1_000)
{:ok, json} = ProcessEvidence.export(evs1k, :ocel2_json)

:ok =
  if byte_size(json) > 10_000, do: :ok, else: raise("bad ocel export size #{byte_size(json)}")

rows = [
  B.measure("stage6_ocel_export_1k", 20, fn ->
    {:ok, j} = ProcessEvidence.export(evs1k, :ocel2_json)
    _d = :crypto.hash(:sha256, j)
    :ok
  end)
  | rows
]

rows = [
  B.measure("stage6_ocel_digest_only_1k", 50, fn ->
    _d = :crypto.hash(:sha256, json)
    :ok
  end)
  | rows
]

rows = Enum.reverse(rows)
IO.puts(JSON.encode!(%{schema: "ash_pplan/tokyo-stage-costs/1", date: "2026-10-03", rows: rows}))

case System.argv() do
  [path] -> File.write!(path, json)
  _ -> :ok
end
