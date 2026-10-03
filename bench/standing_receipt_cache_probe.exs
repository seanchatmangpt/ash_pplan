# Probe: is repeated Standing.receipt/2 over the SAME run evidence cacheable?
#
# 100 receipts of an identical 1k-event run. Is cost O(n) per call with no
# memoization, and what share is the sealed ledger digest (Standing.Chain
# append_pending/append_outcome/seal + verify) vs Receipt.new validation vs
# the OCEL/ex4pm evidence? Compares against the hypothetical saving of a
# naive precomputed-digest shortcut (digest computed once per run, receipt
# assembly reusing the cached digest).
#
#   MIX_BUILD_ROOT=_build-ch15 MIX_ENV=test mix run bench/standing_receipt_cache_probe.exs [out.json]
#
# No Benchee. Harness mirrors bench/standing_closure_bench.exs.

defmodule StandingReceiptCacheProbe do
  @moduledoc false

  alias AshPPlan.ProcessEvidence
  alias AshPPlan.Standing
  alias AshPPlan.Standing.Chain

  @batches 7
  @reps 100

  # -- fixture (chain_run shape from bench/standing_closure_bench.exs) -------

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)

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

  # -- harness ----------------------------------------------------------------

  defp mean_us(fun) do
    for _ <- 1..3, do: fun.()

    times =
      for _ <- 1..@batches do
        {us, _} = :timer.tc(fn -> for _ <- 1..@reps, do: fun.() end)
        us / @reps
      end

    Enum.sum(times) / @batches
  end

  # -- component probes -------------------------------------------------------

  # The sealed ledger digest exactly as Standing.ledger_digest/3 builds it:
  # 2n Chain appends + seal + Chain.verify (verify runs because events != []).
  defp digest_work(run) do
    events = run.events
    subject = "subject-1"
    final = "ALIVE"

    fn ->
      built =
        Enum.reduce_while(events, {:ok, []}, fn e, {:ok, chain} ->
          task = to_string(e.attributes.task)
          id = to_string(e.id)

          with {:ok, c} <- Chain.append_pending(chain, "p:" <> id, subject, task),
               {:ok, c} <- Chain.append_outcome(c, "o:" <> id, "ALIVE", subject, task) do
            {:cont, {:ok, c}}
          else
            error -> {:halt, error}
          end
        end)

      with {:ok, chain} <- built,
           {:ok, chain} <- Chain.seal(chain, "seal", final, subject) do
        {Chain.head(chain), Chain.verify(chain)}
      else
        _ -> {nil, false}
      end
    end
  end

  # OCEL 2.0 JSON export + sha256 + guarded ex4pm validation (evidence/1).
  defp evidence_work(events) do
    fn ->
      ocel =
        case safe_export(events) do
          {:ok, json} ->
            %{ocel2_sha256: :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)}

          _ ->
            %{}
        end

      Map.put(ocel, :ex4pm, ex4pm_status(events))
    end
  end

  defp safe_export(events) do
    ProcessEvidence.export(events, :ocel2_json)
  rescue
    _ -> {:error, :malformed_events}
  end

  defp ex4pm_status(events) do
    try do
      mod =
        AshPPlan.ProcessEvidence.AshEx4pm

      if Code.ensure_loaded?(mod) and mod.available?() do
        case mod.validate(events) do
          {:ok, _} -> "valid"
          _ -> "invalid"
        end
      else
        "unsupported"
      end
    rescue
      _ -> "invalid"
    end
  end

  def run do
    run_fixture = chain_run(1_000)
    opts = [replay_commands: cmds()]
    events = run_fixture.events

    # sanity: the fixture is ALIVE and the receipt digest is real
    {:ok, receipt} = Standing.receipt(run_fixture, opts)

    IO.puts(
      "  [sanity] standing=#{receipt.standing.value} digest=#{receipt.replay.ledger_digest}"
    )

    total_us = mean_us(fn -> Standing.receipt(run_fixture, opts) end)

    digest_us = mean_us(digest_work(run_fixture))
    evidence_us = mean_us(evidence_work(events))
    verdicts_us = mean_us(fn -> Standing.verdicts(run_fixture) end)

    # cached-digest hypothetical: everything except the digest work
    cached_us = total_us - digest_us

    %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      otp: System.otp_release(),
      elixir: System.version(),
      events: 1_000,
      reps: @reps,
      receipt_total_us: Float.round(total_us, 2),
      ledger_digest_us: Float.round(digest_us, 2),
      digest_share_pct: Float.round(100 * digest_us / total_us, 1),
      evidence_ocel_ex4pm_us: Float.round(evidence_us, 2),
      evidence_share_pct: Float.round(100 * evidence_us / total_us, 1),
      verdicts_us: Float.round(verdicts_us, 2),
      verdicts_share_pct: Float.round(100 * verdicts_us / total_us, 1),
      assembly_residual_us: Float.round(total_us - digest_us - evidence_us - verdicts_us, 2),
      cached_digest_hypothetical_us: Float.round(cached_us, 2),
      cached_saving_pct: Float.round(100 * (total_us - cached_us) / total_us, 1)
    }
  end
end

out =
  case System.argv() do
    [path | _] -> path
    _ -> nil
  end

results = StandingReceiptCacheProbe.run()

IO.puts("""
== Standing.receipt/2 cache probe — 1k events, #{results.reps} receipts ==
  total                 #{results.receipt_total_us} us/call
  ledger digest         #{results.ledger_digest_us} us  (#{results.digest_share_pct}%)
  ocel+ex4pm evidence   #{results.evidence_ocel_ex4pm_us} us  (#{results.evidence_share_pct}%)
  verdicts (3 layers)   #{results.verdicts_us} us  (#{results.verdicts_share_pct}%)
  assembly residual     #{results.assembly_residual_us} us
  cached-digest hypoth. #{results.cached_digest_hypothetical_us} us/call (saves #{results.cached_saving_pct}%)
""")

if out do
  File.write!(out, Jason.encode!(results, pretty: true))
  IO.puts("wrote #{out}")
end
