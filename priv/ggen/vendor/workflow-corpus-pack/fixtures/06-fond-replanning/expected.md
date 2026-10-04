# Fixture 06 - FOND nondeterministic outcome / strong-cyclic replanning

## Goal

Deliver the quarterly report bundle to the operator over an unreliable HTTP transport.
The send step's outcome set is genuinely nondeterministic: `delivered`,
`transport-refused`, `endpoint-unreachable`. The plan is strong-cyclic only if EVERY
failure outcome has a recovery path back to the goal.

## Nondeterministic task

`wfc:f06-task-deliver` (`send-report-bundle`, typed `task:fond-step`): one
`Http.Post` whose outcome the planner cannot determine in advance.

## Outcome set and recovery arcs

| outcome | class | recovery path |
|---|---|---|
| `outcome:delivered` | success | goal reached; Evidence.Establish delivery receipt issued |
| `outcome:transport-refused` | failure | `re-resolve-and-resend`: Endpoint.Resolve against the registry, then re-enter the send task (cycle back to goal) |
| `outcome:endpoint-unreachable` | failure | `write-bundle-to-local-drop`: admitted local fallback realization (File.Write to the operator drop directory + delivery receipt) |

Strong-cyclic expectation: from every failure outcome there exists a path whose
continued execution still reaches the goal. Recovery is not abandonment: the local
fallback achieves the goal through a different admitted realization.

## Evidence

The `delivered` outcome carries an Evidence.Establish delivery receipt; a
recovery-path arrival carries the same class of receipt (`wfc:requiredEvidence`).

## Authority

`Http.Post` grant scoped to the resolved endpoint; `Endpoint.Resolve` grant scoped to
the registry base URL. No ambient network authority: each retry after a failure outcome
re-reads its own grant (`wfc:requiredAuthority`).

## Expected provider closure

| realization | capability | provenance class |
|---|---|---|
| `Reactor.Req.Post` | Http.Post (send + re-endpoint retry) | hex metadata only (no local inspection) |
| `Reactor.File.WriteFile` | File.Write (local fallback) | hex metadata only (no local inspection) |
| `xaas` ExecutionProvider routing | Endpoint.Resolve | observed at `~/xaas` |

## Forbidden realization

A happy-path-only plan that treats the failure outcomes as impossible, or terminates
the workflow on a failure outcome without a recovery arc back to the goal.

## Falsifier

`wfc:f06-falsifier`: the engine fails if it assumes the happy path only - any failure
outcome lacking a recovery path back to the goal, or a plan that terminates on a
failure outcome without reaching the goal through a recovery realization.

## Gate and firing witnesses

Gate `gates/f06_fond_replanning.rq` returns one violation row per failure outcome with
no recovery path (no `dcterms:relation` pointing at a `prov:Activity` recovery task).
Witnesses in this directory:

- `negative-happy-path.ttl` - `outcome:transport-refused` present with NO recovery
  relation (the engine that only modeled the happy path). Fires `E-F06-NO-RECOVERY-PATH`.
- `negative-untyped-recovery.ttl` - failure outcome carries `dcterms:relation` but the
  target is a bare node, not a typed `prov:Activity` recovery task. Fires
  `E-F06-NO-RECOVERY-PATH`.

The clean `fixture.ttl` must return zero rows.
