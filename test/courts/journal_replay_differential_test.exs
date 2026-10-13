defmodule AshPPlan.Courts.JournalReplayDifferentialTest do
  @moduledoc """
  Cross-anchor differential court: mfact `ProcInt.StrataStore.JournalReplay.lean`
  (`/Users/sac/mfact/procint/ProcInt/Petri/JournalReplay.lean`) vs. the REAL durable
  engine on a REAL DETS store.

  ## The Lean law (as proved, not as paraphrased)

  `JournalReplay.lean` models the journal as `List Key`, head = newest, undo pops the
  head. Its theorems, verbatim:

    * `crash_undo_all` / `recover_after_crash` — `recover (crash_at k j target) target =
      undo_all j target` for EVERY crash position `k` (including `k = 0` and over-count
      `k`): crash position is invisible in the final state.
    * `undo_all_idem` / `recover_recover` — re-invoked recovery after completion is a
      no-op.
    * `rollback_interleaved_diverges` (honest negative) — pop-only recovery cannot
      restore entries truncated below the target while an undo is pending; that is
      exactly why the runtime REFUSES (`UndoInterruptedPending`) instead of
      replaying over a shortened journal.

  Generalized law class (Petri journals → any durable decision journal): **journal-prefix
  law** — the committed prefix survives crash/reopen, replay of that prefix lands on the
  same state as uninterrupted execution, recovery is idempotent, and a divergence during
  replay is a REFUSAL that never truncates the committed prefix and never terminates the
  run.

  ## Law mapping (Lean → ash_pplan)

    | Lean                           | executable witness here                                        |
    |--------------------------------|----------------------------------------------------------------|
    | journal `j : List Key`         | the DETS-backed policy-decision ledger (`Engine.steps`)         |
    | `undo_all j target` (clean)    | an uninterrupted `Engine.drive_policy` to completion (control)  |
    | `crash_at k j target`          | drive `k` decisions, then HARD-KILL the DETS store (`exit :kill`) |
    | `recover j target`             | re-`drive_policy` on the reopened store, same driver             |
    | `recover_after_crash`          | re-driven result == uninterrupted control result, every `k`      |
    | `recover_recover`              | re-drive after completion → `:ended`, digest unchanged           |
    | `rollback_interleaved_diverges`| forged-driver re-drive → `{:refused, {:policy_replay_divergence}}`, run non-terminal, committed prefix intact |

  Sabotage twin: the Lean law is encoded a second time as a pure executable model in this
  file (`AshPPlan.Courts.JournalReplayLaw`); a mutant of `crash_at` that applies RAW pops
  (the exact untargeted-pop deviation `JournalReplay.lean` itself documents at its modeling
  note) violates `recover_after_crash`, and this court asserts the violation is detected.

  Chicago: real DETS file, real process kill, real engine, assertions on real reopened
  state. No mocks.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Courts.JournalReplayDifferentialTest.JournalReplayLaw
  alias AshPPlan.FOND
  alias AshPPlan.Reactor.Durable.Engine
  alias AshPPlan.Reactor.Durable.PolicyDriver
  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.Reactor.Durable.Testing

  @transitions %{
    start: %{charge_primary: [:mid], charge_backup: [:paid]},
    mid: %{finalize: [:paid]},
    paid: %{}
  }

  setup do
    # the store is hard-killed below; the test process start_link'd it
    Process.flag(:trap_exit, true)
    path =
      Path.join(
        System.tmp_dir!(),
        "ash_pplan_journal_replay_court_#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn ->
      File.rm(path)
      File.rm_rf(path <> ".backup")
    end)

    {:ok, d} = FOND.new(@transitions, [:paid])
    {:ok, driver} = PolicyDriver.new(d, :start, policy: %{start: :charge_primary, mid: :finalize, paid: :none})
    {:ok, forged} = PolicyDriver.new(d, :start, policy: %{start: :charge_backup, mid: :finalize, paid: :none})

    {:ok, path: path, driver: driver, forged: forged}
  end

  # -- (a) journal-prefix law: committed entries survive reopen ----------------------------------

  @tag timeout: 60_000
  test "recover_after_crash: committed prefix survives kill/reopen at every crash position k" do
    for k <- [0, 1, 2] do
      path = dets_path()
      {:ok, s} = Dets.start_link(path: path)

      # Control: the clean undo_all — one uninterrupted drive to completion.
      {:ok, _} = Engine.start(s, %{id: "control"})
      assert {:completed, control} =
               Engine.drive_policy(s, "control",
                 policy: driver(),
                 execute: provider(),
                 max_steps: 10
               )

      # Crash position k: commit k decisions, then hard-kill the store.
      {:ok, _} = Engine.start(s, %{id: "crash-#{k}"})

      assert {:refused, {:policy_step_limit, ^k}} =
               Engine.drive_policy(s, "crash-#{k}",
                 policy: driver(),
                 execute: provider(),
                 max_steps: k
               )

      committed = Engine.steps(s, "crash-#{k}", store_module: Dets)
      assert length(committed) == k

      ref = Process.monitor(s)
      Process.exit(s, :kill)
      assert_receive {:DOWN, ^ref, :process, ^s, :killed}, 5_000
      flush_exit()

      # REOPEN: the committed prefix must be intact, byte-for-byte (prefix law).
      {:ok, s2} = Dets.start_link(path: path)

      survived = Engine.steps(s2, "crash-#{k}", store_module: Dets)
      assert survived == committed, "crash position #{k}: committed prefix lost across reopen"

      # recover(crash_at k) == undo_all: the re-drive lands on the control result.
      assert {:completed, result} =
               Engine.drive_policy(s2, "crash-#{k}",
                 policy: driver(),
                 execute: provider(),
                 max_steps: 10
               )

      assert result.goal == control.goal

      assert result.decisions == control.decisions,
             "crash position #{k}: replay landed on a different state than the clean undo"

      :ok = GenServer.stop(s2)
      File.rm(path)
      File.rm_rf(path <> ".backup")
    end
  end

  # -- (b) committed-prefix survival under later divergence + (c) refusal non-terminal ------------

  @tag timeout: 60_000
  test "rollback_interleaved_diverges: refusal never truncates the committed prefix, stays non-terminal, re-derives identically" do
    path = dets_path()
    {:ok, s} = Dets.start_link(path: path)
    {:ok, _} = Engine.start(s, %{id: "divergence"})

    # Commit one real decision, then kill/reopen (crash position k = 1).
    assert {:refused, {:policy_step_limit, 1}} =
             Engine.drive_policy(s, "divergence", policy: driver(), execute: provider(), max_steps: 1)

    ref = Process.monitor(s)
    Process.exit(s, :kill)
    assert_receive {:DOWN, ^ref, :process, ^s, :killed}, 5_000
    flush_exit()

    {:ok, s2} = Dets.start_link(path: path)
    [cp] = Engine.steps(s2, "divergence", store_module: Dets)
    prefix_digest = ledger_digest(s2, "divergence")

    # The forged driver re-decides a DIFFERENT action at step 0: replay divergence.
    # Lean anchor: rollback_interleaved_diverges — the runtime must REFUSE, not replay
    # over the shortened/decided-otherwise journal (mfact JournalReplay.lean, L167-178).
    assert {:refused, {:policy_replay_divergence, div}} =
             Engine.drive_policy(s2, "divergence",
               policy: forged(),
               execute: provider(),
               max_steps: 5
             )

    assert div.step == 0
    div_digest = refusal_digest({:policy_replay_divergence, div})

    # Refusals are non-terminal AND never truncate the committed prefix.
    assert Testing.status(s2, "divergence") == :pending
    assert Engine.steps(s2, "divergence", store_module: Dets) == [cp]
    assert ledger_digest(s2, "divergence") == prefix_digest

    :ok = GenServer.stop(s2)

    # Second kill/reopen: the refusal re-derives IDENTICALLY (c), prefix still intact.
    {:ok, s3} = Dets.start_link(path: path)

    assert {:refused, {:policy_replay_divergence, div2}} =
             Engine.drive_policy(s3, "divergence",
               policy: forged(),
               execute: provider(),
               max_steps: 5
             )

    assert refusal_digest({:policy_replay_divergence, div2}) == div_digest
    assert Testing.status(s3, "divergence") == :pending
    assert ledger_digest(s3, "divergence") == prefix_digest

    # And the honest recovery still completes to the clean undo (prefix never damaged).
    assert {:completed, result} =
             Engine.drive_policy(s3, "divergence",
               policy: driver(),
               execute: provider(),
               max_steps: 10
             )

    assert %{goal: :paid, decisions: [_d0, _d1]} = result
    assert length(Engine.steps(s3, "divergence", store_module: Dets)) == 2

    :ok = GenServer.stop(s3)
  end

  # -- (d) recover_recover: idempotence -----------------------------------------------------------

  @tag timeout: 60_000
  test "recover_recover: re-driving a completed run is a no-op (digest unchanged)" do
    path = dets_path()
    {:ok, s} = Dets.start_link(path: path)
    {:ok, _} = Engine.start(s, %{id: "idem"})
    {:ok, _} = Engine.start(s, %{id: "idem-control"})

    assert {:completed, _} =
             Engine.drive_policy(s, "idem", policy: driver(), execute: provider(), max_steps: 10)

    assert {:completed, control} =
             Engine.drive_policy(s, "idem-control", policy: driver(), execute: provider(), max_steps: 10)

    before = ledger_digest(s, "idem")
    run_before = Dets.get_run(s, "idem")

    # Lean anchor: recover_recover / undo_all_idem (mfact JournalReplay.lean, L114-119).
    assert Engine.drive_policy(s, "idem", policy: driver(), execute: provider(), max_steps: 10) ==
             :ended

    assert Dets.get_run(s, "idem") == run_before
    assert ledger_digest(s, "idem") == before

    # The completed run's recorded decisions match the clean control's.
    run = Dets.get_run(s, "idem")
    assert run.status == :completed
    assert run.result.decisions == control.decisions
    :ok = GenServer.stop(s)
  end

  # -- sabotage twin -------------------------------------------------------------------------------

  @tag timeout: 30_000
  test "sabotage twin: the raw-pop mutant of crash_at violates recover_after_crash and is detected" do
    # Faithful encoding of the Lean law (JournalReplay.lean L63-83).
    j = [3, 2, 1]
    target = 1

    for k <- [0, 1, 3, 7] do
      assert JournalReplayLaw.recover_after_crash?(k, j, target),
             "faithful law fails at k=#{k} (encoding bug, not a court verdict)"
    end

    # The mutant: crash pops are NOT target-guarded (raw pops past the target) — the
    # exact deviation JournalReplay.lean's modeling note rules out (L24-31). Entries are
    # lost below the target and recovery (pop-only) cannot restore them.
    for k <- [3, 7] do
      refute JournalReplayLaw.recover_after_crash_mutant?(k, j, target),
             "mutant k=#{k}: raw-pop crash should violate the law but did not"
    end
  end

  # -- helpers --------------------------------------------------------------------------------------

  defp dets_path,
    do:
      Path.join(
        System.tmp_dir!(),
        "jrp-#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}.dets"
      )

  defp driver do
    {:ok, d} = FOND.new(@transitions, [:paid])
    {:ok, driver} = PolicyDriver.new(d, :start, policy: %{start: :charge_primary, mid: :finalize, paid: :none})
    driver
  end

  defp forged do
    {:ok, d} = FOND.new(@transitions, [:paid])
    {:ok, forged} = PolicyDriver.new(d, :start, policy: %{start: :charge_backup, mid: :finalize, paid: :none})
    forged
  end

  defp provider,
    do: fn
      :charge_primary, _ctx -> {:ok, :mid}
      :finalize, _ctx -> {:ok, :paid}
      :charge_backup, _ctx -> {:ok, :paid}
    end

  defp ledger_digest(s, id),
    do:
      s
      |> Engine.steps(id, store_module: Dets)
      |> Enum.map(&{&1.step_key, &1.output})
      |> :erlang.term_to_binary([:deterministic, minor_version: 2])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  defp flush_exit do
    receive do
      {:EXIT, _pid, _reason} -> flush_exit()
    after
      0 -> :ok
    end
  end

  defp refusal_digest(refusal),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(refusal, [:deterministic, minor_version: 2]))
      |> Base.encode16(case: :lower)

  # The executable Lean law, embedded so the court is self-contained (no mfact read at
  # test time; the Lean source is anchored above).
  defmodule JournalReplayLaw do
    @moduledoc false
    # Journal := list of keys, head = newest; undo pops the head (JournalReplay.lean L59-83).

    def undo_step([]), do: []
    def undo_step([_ | t]), do: t

    def undo_all(j, target)
    def undo_all([], _target), do: []

    def undo_all([h | t], target) do
      if length(t) < target, do: [h | t], else: undo_all(t, target)
    end

    # Faithful crash_at: each pop target-guarded, as the runtime recovery loop is.
    def crash_at(0, j, _target), do: j

    def crash_at(k, j, target) do
      if length(j) <= target, do: j, else: crash_at(k - 1, undo_step(j), target)
    end

    def recover(j, target), do: undo_all(j, target)

    # recover_after_crash: recover (crash_at k j target) target == undo_all j target.
    def recover_after_crash?(k, j, target),
      do: recover(crash_at(k, j, target), target) == undo_all(j, target)

    # SABOTAGED twin: crash pops are raw (un-guarded), the deviation the Lean modeling
    # note rules out. Raw pops past the target lose entries below it; pop-only recovery
    # cannot restore them, so the law check FAILS — which is what this court asserts.
    def crash_at_mutant(0, j, _target), do: j

    def crash_at_mutant(k, j, target) do
      if j == [], do: j, else: crash_at_mutant(k - 1, undo_step(j), target)
    end

    def recover_after_crash_mutant?(k, j, target),
      do: recover(crash_at_mutant(k, j, target), target) == undo_all(j, target)
  end
end
