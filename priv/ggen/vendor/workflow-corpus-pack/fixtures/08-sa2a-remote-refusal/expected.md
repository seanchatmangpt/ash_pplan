# Fixture 08 - distributed SA2A execution with a remote authority envelope

## Goal

Compute a jurisdiction tax quote by invoking a remote SA2A agent - discover its agent
card (`A2A.Discover`), invoke under a verified authority envelope (`A2A.Invoke`
preceded by `Authority.Verify`), await the task (`A2A.Await`) - and on a typed remote
refusal fall back to the admitted local Ash realization. The remote call must never
run on ambient authority.

## Task structure

| task | type | authority requirement |
|---|---|---|
| `invoke-remote-tax-agent` | `task:a2a-invoke` | `lease:a2a-tax-agent-invoke` + `envelope:AshA2A.StandingBinding`, associated with `wfc:f08-envelope` (a typed `authority:envelope` entity) |
| `await-remote-tax-task` | `task:a2a-await` | same lease |
| `compute-tax-quote-locally` | `task:local-realization` | its own `grant:Domain.Action.Invoke.tax-quote` |

## Outcome set (typed, first-class)

| outcome | class | handling |
|---|---|---|
| `outcome:remote-completed` | success | AshA2A runtime receipt bound as evidence |
| `outcome:remote-refused` | failure (typed: e.g. `REFUSED_NO_AUTHORITY`, `REFUSED_GENERATOR_OWNED`) | refusal record bound; alternate local realization ADMITTED via `dcterms:relation` to `compute-tax-quote-locally` |
| `outcome:remote-unreachable` | failure | falls back to the local realization |

A remote refusal is a first-class outcome with a bound refusal record, never an
untyped crash.

## Evidence

Every terminal outcome leaves evidence: runtime receipt (remote-completed), typed
refusal record (remote-refused), Domain.Action.Invoke receipt (local fallback). A
quote with no bound receipt is not a goal state (`wfc:requiredEvidence`).

## Authority

`A2A.Invoke` requires a lease-scoped authority envelope verified by `Authority.Verify`
BEFORE dispatch, bound to the remote agent's standing binding. The local fallback runs
under its own named grant. No ambient authority: session context never substitutes for
the envelope (`wfc:requiredAuthority`).

## Expected provider closure

| realization | capability | provenance class |
|---|---|---|
| `AshA2A.Dispatcher` | A2A.Invoke | observed at `~/ash_a2a/lib/ash_a2a/dispatcher.ex` |
| `AshA2A.TaskLifecycle` + `AshA2A.Delivery` | A2A.Await | observed at `~/ash_a2a/lib/ash_a2a/{task_lifecycle,delivery}.ex` |
| `AshA2A.StandingBinding` + `AshA2A.SafeExec` + `AshA2A.RuntimeReceipt` | Authority.Verify, evidence binding | observed at `~/ash_a2a/lib/ash_a2a/{standing_binding,safe_exec,runtime_receipt}.ex` |
| `Ash.Reactor` (`reactor.ash_action` step) | Domain.Action.Invoke (local fallback) | hex metadata only (no local inspection) |
| `AshAffidavit.Resource.Persist` | Evidence.Establish (refusal + fallback receipts) | observed at `~/ash_affidavit/lib/ash_affidavit/persist.ex` |

## Forbidden realization

`Http.Post` standing in for `A2A.Invoke` without a verified authority envelope;
inheriting the operator session's ambient authority for the remote call; realizing the
local fallback with an unverified remote endpoint retry.

## Falsifier

`wfc:f08-falsifier`: the engine fails if it treats remote authority as ambient - an
`A2A.Invoke` step dispatched without a lease-scoped envelope requirement, a fixture
using `A2A.Invoke` with no `Authority.Verify` requirement anywhere in its capability
set, or a remote refusal handled as an untyped crash instead of a first-class outcome
with an admitted alternate local realization.

## Gate and firing witnesses

Gate `gates/f08_sa2a_remote_refusal.rq` returns violation rows for either adversarial
condition. Witnesses in this directory:

- `negative-ambient-authority.ttl` - the a2a-invoke task declares NO
  `dcterms:requires` lease/envelope requirement (engine assumed ambient authority).
  Fires branch `E-F08-AMBIENT-AUTHORITY`.
- `negative-unverified-envelope.ttl` - the fixture requires `A2A.Invoke` but omits
  `Authority.Verify` from its capability set entirely. Fires branch
  `E-F08-UNVERIFIED-ENVELOPE`.

The clean `fixture.ttl` must return zero rows.
