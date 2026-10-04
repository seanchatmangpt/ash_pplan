# Fixture 03 - human approval with halt/resume

Semantic subject: a workflow that halts at a human approval boundary, holds an
AUTHORITY GAP while halted (the pre-halt envelope is released, not parked),
and resumes after approval only under freshly bound authority. The trap: an
engine that keeps authority live across the halt, or accepts the stale
envelope at resume time.

## Goal

Prepare a destructive-change dossier, halt at the approval boundary releasing
held authority, and after approval resume under fresh authority; a resume that
reuses the pre-halt envelope must be refused as a typed authority failure.

## Tasks

| # | task | capability (pinned literal) | informs | expected outcomes |
|---|------|------------------------------|---------|-------------------|
| 1 | `f03-prepare-dossier` | `Domain.Query.Read` | 2 | `dossier-ready` |
| 2 | `f03-halt-for-approval` | `Workflow.Halt` | 3 | `halted-awaiting-approval` |
| 3 | `f03-resume-after-approval` | `Workflow.Resume` | - | `resumed-under-fresh-authority` OR `resume-stale-authority-refused` |

Task 2 is informed by task 1; task 3 is informed by task 2 (the resume
continues THAT suspension).

## Expected decomposition

`dossier-then-halt-then-resume`, strictly ordered. Between tasks 2 and 3 the
workflow is halted with an open authority gap of unbounded wall-clock
duration; nothing else may execute on the workflow's behalf during the gap.

## Authority timeline (the adversarial core)

| phase | authority state |
|-------|-----------------|
| dossier | none needed (read-only) |
| halt executed | pre-halt envelope RELEASED; gap opens |
| while halted | NONE -- the gap is part of the subject |
| resume (lawful) | FRESH operator grant bound to the same workflow identity |
| resume (stale envelope) | typed refusal, class `refused_authority`; continuation stays halted |

## Required evidence

Read receipt (dossier); halt record (continuation identity + released
envelope); resume receipt binding the NEW grant and the same continuation
identity. A resumed continuation with no fresh-grant receipt is not a goal
state.

## Required authority

`Workflow.Halt` is deliberately NOT in the consequential authority set (a halt
suspends; it does not actuate). `Workflow.Resume` is: it consumes the fresh
grant.

## Expected provider closure

| realization | capability | citation class |
|-------------|------------|----------------|
| `AshAffidavit.call/2` | Domain.Query.Read evidence | local checkout `~/ash_affidavit` -- read-only inspection |
| `AshA2A.TaskLifecycle` | Workflow.Halt / Workflow.Resume records | local checkout `~/ash_a2a` -- read-only inspection (module surface) |
| `AshAffidavit.Refusal.new/3` (`refused_authority`) | stale-authority refusal branch | local checkout `~/ash_affidavit` -- read-only inspection |

## Forbidden realization

`resume-under-stale-authority` -- accepting the pre-halt envelope (or no
grant) at resume time.

## Falsifier (kills a mishandling engine)

A resume receipt naming the pre-halt envelope (or naming no grant) exists; or
a resume executes with no halt record in the same episode; or authority is
observed live during the gap.

## Gate

`gates/f03_resume_rebinds_authority.rq` -- fires if the `Workflow.Resume`
task's fixture declares no `wfc:requiredAuthority`, or the resume is not
informed by the `Workflow.Halt` task. Negative witness:
`witnesses/fail/f03_resume_rebinds_authority.ttl`.
