# Journal Replay Differential Court

Cross-anchor court: mfact `ProcInt.StrataStore.JournalReplay.lean`
(`/Users/sac/mfact/procint/ProcInt/Petri/JournalReplay.lean`) against ash_pplan's REAL
durable engine on a REAL DETS store.

## The Lean law

`JournalReplay.lean` proves, over `Journal := List Key` (head = newest, undo pops the
head):

- `crash_undo_all` / `recover_after_crash` — recovery after a crash at ANY position
  `k` (including `k = 0` and over-count `k`) equals the clean undo; crash position is
  invisible in the final state.
- `undo_all_idem` / `recover_recover` — re-invoked recovery after completion is a no-op.
- `rollback_interleaved_diverges` — pop-only recovery cannot restore entries truncated
  below the target while an undo is pending; that is why the runtime REFUSES
  (`UndoInterruptedPending`) instead of replaying over a shortened journal.

## Law mapping (Lean → ash_pplan)

The shared law class: journal-prefix + committed-prefix survival + refusal-nonterminal
replay semantics.

| Lean | executable witness in the court |
|---|---|
| journal `j : List Key` | the DETS-backed policy-decision ledger (`Engine.steps`) |
| `undo_all j target` | an uninterrupted `Engine.drive_policy` to completion (control) |
| `crash_at k j target` | drive `k` decisions, then HARD-KILL the DETS store |
| `recover j target` | re-`drive_policy` on the reopened store, same driver |
| `recover_after_crash` | re-driven result == control result, for every `k` in {0,1,2} |
| `recover_recover` | re-drive after completion → `:ended`, ledger digest unchanged |
| `rollback_interleaved_diverges` | forged-driver re-drive → `{:refused, {:policy_replay_divergence}}`, run non-terminal, committed prefix intact, refusal re-derives identically across a second kill/reopen |

## Sabotage twin

The law is encoded a second time as a pure executable model in the test
(`JournalReplayLaw`): `undo_all`/`crash_at`/`recover` mirror the Lean definitions. A
mutant of `crash_at` with RAW (untargeted) pops — the exact deviation the Lean modeling
note rules out — violates `recover_after_crash` for over-count `k`, and the court asserts
the violation is detected (anti-vacuity: the check carries bits).

## Verdict

- Law transfer: CLEAN. All three Lean theorems have honest executable witnesses over the
  real engine; no divergence finding required.
- Replay command:
  `mix test test/courts/journal_replay_differential_test.exs` (4 tests, 0 failures).

See Also: `test/burn_in/dets_refusal_restart_court_test.exs` ·
`test/durable/store_differential_test.exs`
