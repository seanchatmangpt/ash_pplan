# Shared fixtures for the standing cache courts (receipt_cached, cached_adversarial,
# cached_single_flight, ladder_digest_work). One run/2 builder and one opts/0 instead
# of four drifted copies. Loaded with Code.require_file from each test file; this
# file is not a test and is skipped by mix test's *_test.exs selection.
defmodule AshPPlan.Standing.Fixtures do
  @moduledoc """
  Real `AshPPlan.Standing.receipt/2` input maps: an n-task chain run with one
  succeeded event per task, provider `p<i>` selected per task. Byte-identical to
  the former per-file copies, so digests and identities are unchanged.
  """

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)

  @doc "An evidenced n-task chain run (default 4) under run_id (default \"r1\")."
  def run(n \\ 4, run_id \\ "r1") do
    tasks = for i <- 1..n, do: %{id: :"t#{i}", depends_on: (i == 1 && []) || [:"t#{i - 1}"]}

    events =
      for i <- 1..n do
        %AshPPlan.ProcessEvidence.Event{
          id: "run:#{run_id}/t#{i}",
          activity: "task_succeeded",
          timestamp: ~U[2026-10-01 00:00:00Z],
          objects: [{"WorkflowRun", "run:#{run_id}", "run"}],
          attributes: %{task: "t#{i}", seq: i, provider: "p#{i}", outcome: nil},
          subject_id: "subject-1"
        }
      end

    attempts = Map.new(1..n, fn i -> {:"t#{i}", 1} end)

    %{
      run_id: run_id,
      repo: "ash_pplan",
      head: @head,
      base: @base,
      events: events,
      model: %{tasks: tasks},
      selection: Map.new(1..n, fn i -> {"t#{i}", :"p#{i}"} end),
      fond_gates: [],
      execution: {attempts, attempts},
      consequence: [chain_complete: true],
      observation: %{tasks_completed: n}
    }
  end

  @doc "Replay options shared by the cache courts."
  def opts, do: [replay_commands: [%{cmd: "mix test", cwd: File.cwd!(), exit: 0}]]
end
