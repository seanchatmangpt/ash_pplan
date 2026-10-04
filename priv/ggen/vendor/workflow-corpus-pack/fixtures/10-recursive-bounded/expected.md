# Fixture 10 - dynamic recursive workflow (bounded, same-shape)

## Goal

Drain a bounded work backlog by a workflow whose recursive step spawns a sub-workflow of
the SAME task shape (the pinned task individual itself), with the recursion depth bound
explicit (maximum depth 4) and every frame's semantic identity preserved by a per-depth
checkpoint.

## Structure (the adversarial core)

The compound task `drain-backlog` decomposes `observe -> checkpoint -> (recurse | halt)`:

| step | capability | role |
|---|---|---|
| `observe-remaining-work` | State.Observe | emits `remaining.count`, `current.depth` |
| `checkpoint-frame-identity` | Durability.Checkpoint | binds the parent frame digest |
| `invoke-child-frame` | A2A.Invoke | role:recursive-step; `prov:wasDerivedFrom` THE SAME task; `dcterms:extent "4"^^xsd:integer`; guard `depth<4` |
| `halt-at-bound` | Workflow.Halt | guard `depth>=4` |

The recursion is same-shape BY CONSTRUCTION: the recursive step's `prov:wasDerivedFrom`
points at the pinned task individual `wfc:f10-task-drain` itself, so every frame is that
task's shape - not merely "similar". Two invariants make this adversarial:

1. **Explicit bound**: the depth bound is a typed integer (`dcterms:extent "4"^^xsd:integer`)
   on the recursive step. A recursion whose bound is prose-only or absent admits unbounded
   descent.
2. **Identity across depth**: each frame chains to its parent via the checkpoint digest;
   a child resolved to a different task shape or an anonymous sub-workflow loses the
   semantic identity of the recursion (it is no longer "the same workflow, one level deep").

## Expected engine behavior

The engine must admit the recursion only with the explicit integer bound attached to the
recursive step, and must keep the recursive child bound to the pinned task identity at
every depth.

## Outcomes

- `outcome:drained` (success): backlog drained through at most 4 nested same-shape frames;
  every frame's identity chains to its parent via the checkpoint digest; the halt receipt
  records the bound and the observed terminal depth.

## Evidence

Each recursion frame carries a Durability.Checkpoint receipt whose digest is bound into the
child frame's A2A.Invoke receipt, so depth d and depth d+1 are one continuing workflow
identity; the halt receipt records the bound (4) and the observed terminal depth
(`wfc:requiredEvidence`).

## Authority

Session-local CONSTRUCT ceiling: A2A.Invoke may spawn child sub-workflows only of the
pinned same task shape and only under the declared depth bound; each frame inherits no
authority beyond the parent frame's grant. No ambient authority (`wfc:requiredAuthority`).

## Expected provider closure

| realization | capability | provenance class |
|---|---|---|
| `AshGraphlaw.Lifecycle.Run` | State.Observe | observed at `~/ash_graphlaw/lib/ash_graphlaw/lifecycle.ex` (`run/4`) |
| `AshA2A.Actuation` | A2A.Invoke | observed at `~/ash_a2a/lib/ash_a2a/actuation.ex` |
| `Xaas.Actuation.Refusal` | Workflow.Halt | observed at `~/xaas/lib/xaas/actuation/refusal.ex` |
| `AshAffidavit.Resource.Persist` | Durability.Checkpoint | observed at `~/ash_affidavit/lib/ash_affidavit/persist.ex` |

## Forbidden realization

Recursing without an explicit integer depth bound (unbounded recursion); resolving the
recursive child to a different task shape or an anonymous sub-workflow (semantic identity
lost across depth).

## Falsifier

`wfc:f10-falsifier`: the engine fails if it admits an unbounded recursion (the recursive
step carrying no explicit integer depth bound), or if it loses semantic identity across
recursion depth (the recursive invocation no longer targets the pinned same task
individual).

## Gate and firing witnesses

Gate `gates/f10_recursive-bounded.rq` returns violation rows when either adversarial
condition holds. Both branches are witnessed by malformed variants in this directory:

- `negative-unbounded-recursion.ttl` - clean same-shape identity, but the recursive step
  carries no `dcterms:extent` depth bound. Fires branch `E-F10-UNBOUNDED-RECURSION`
  (and only it).
- `negative-recursion-identity-loss.ttl` - depth bound intact, but the recursive step
  derives from a foreign task instead of the fixture's own pinned task. Fires branch
  `E-F10-RECURSION-IDENTITY-LOST` (and not the unbounded branch).

The clean `fixture.ttl` must return zero rows.
