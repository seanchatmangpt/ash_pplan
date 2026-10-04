# Fixture 07 - durability + evidence: crash mid-flight, replay to completion

## Goal

Run a three-task record migration (`migrate-records`, `verify-counts`,
`emit-receipt`) that survives a simulated crash after `migrate-records` completes:
a `Durability.Checkpoint` is taken, the workflow halts (`Workflow.Halt`), and the
replay (`Durability.Replay` under a `Workflow.Resume` grant) completes the remaining
tasks WITHOUT re-executing any task that already has a completion receipt, and
WITHOUT dropping any unevidenced task.

## Task pool and decompositions

Task pool: `f07-sub-migrate`, `f07-sub-verify`, `f07-sub-emit` (each `prov:Activity`
with a pinned `dcterms:identifier`).

| decomposition | method | ordered set |
|---|---|---|
| `wfc:f07-decomp-pre-crash` | `method:pre-crash-forward` | (migrate, verify, emit) |
| `wfc:f07-decomp-replay` | `method:post-crash-replay` | (verify, emit) |

The crash point `wfc:f07-task-crash` (typed `task:crash`) sits after
`migrate-records` is evidenced.

## Outcomes

- `outcome:replayed-complete` (success): replay reaches the goal - verify-counts and
  emit-receipt complete with fresh receipts, migrate-records executes exactly once
  (its pre-crash receipt is reused, never re-earned), and the workflow emits a
  whole-workflow receipt binding all three task receipts.

## Evidence

`wfc:f07-receipt-migrate` is a `prov:Entity` typed
`evidence:completion-receipt` with `prov:wasGeneratedBy wfc:f07-sub-migrate` - the
receipt that exists BEFORE the crash and is the replay's justification for skipping
`migrate-records`. Every completed task must have such a receipt, signed via
`Receipt.Sign` and bound via `Evidence.Bind` (`wfc:requiredEvidence`).

## Authority

`Durability.Replay` resumes only under a `Workflow.Resume` grant naming the checkpoint
digest; `Receipt.Sign` authority is scoped per task. No ambient resume authority
(`wfc:requiredAuthority`).

## Expected provider closure

| realization | capability | provenance class |
|---|---|---|
| `AshAffidavit.Resource.Persist` | Durability.Checkpoint | observed at `~/ash_affidavit/lib/ash_affidavit/persist.ex` |
| `AshAffidavit.Resource.Verify` + `AshAffidavit.Refusal` | Evidence.Bind verification, typed refusal of re-execution | observed at `~/ash_affidavit/lib/ash_affidavit/{verify,refusal}.ex` |
| `Reactor.File.WriteFile` | File.Write (migrate-records) | hex metadata only (no local inspection) |
| `ash_pplan v26.9.30` replay-resume loop | Durability.Replay, Workflow.Resume | expected consumer closure at `~/ash_pplan` (built in parallel, READ-ONLY; expected, not yet observed) |

## Forbidden realization

A replay loop that ignores completion receipts and re-executes evidenced tasks, or a
resume that drops an unevidenced task from the replay set.

## Falsifier

`wfc:f07-falsifier`: the engine fails if the post-crash replay re-executes a task that
already has a completion receipt (`migrate-records`), or if the replay drops any task
that has no completion receipt (`verify-counts`, `emit-receipt`) from the replay set -
losing an outcome.

## Gate and firing witnesses

Gate `gates/f07_durability_evidence.rq` returns violation rows for either adversarial
condition. Witnesses in this directory:

- `negative-reexecuted-evidenced.ttl` - replay set includes `migrate-records`, which
  already carries its completion receipt. Fires branch `E-F07-REEXECUTED-EVIDENCED`.
- `negative-lost-outcome.ttl` - replay set is only `(verify)`; `emit-receipt` is
  unevidenced and absent from the replay. Fires branch `E-F07-LOST-OUTCOME`.

The clean `fixture.ttl` must return zero rows.
