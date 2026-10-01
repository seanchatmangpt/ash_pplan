# ash_pplan documentation

These pages are organized by [Diátaxis](https://diataxis.fr/), which splits
documentation into four quadrants by what the reader needs: to **learn**
(tutorials), to **accomplish a task** (how-to guides), to **look something up**
(reference), or to **understand why** (explanation). When adding a page, decide
which need it serves and put it in that quadrant, linked from this index; a
page that mixes quadrants belongs in the quadrant of its primary need.

## Tutorials — learning-oriented

Lessons that take a newcomer through a real unit of work, end to end.

- [Install and first plan](tutorials/install-and-first-plan.md) — install
  `ash_pplan` and take one P-PLAN from ontology-declared topology to an
  observed execution with a receipt.
- [Durable engine tutorial](tutorials/durable-engine-tutorial.md) — run a
  workflow on the reference ETS store, park it on a signal, resume it, and
  watch the checkpoint tape replay.

## How-to guides — task-oriented

Recipes for readers working on a real application problem.

- [Execute a plan](how-to/execute-a-plan.md) — run a compiled P-PLAN through
  the authorized Ash action boundary (`AshPPlan.Action.Run`) or the lower-level
  engine API.
- [Validate a FOND policy](how-to/validate-a-fond-policy.md) — check or
  synthesize strong and strong-cyclic policies over a nondeterministic domain,
  without actuating anything.
- [Schedule work with AshOban](how-to/schedule-work-with-ashoban.md) — describe
  a resource's resolved AshOban triggers and build a trigger changeset at the
  CONSTRUCT boundary.
- [Add a durable store backend](how-to/add-a-durable-store-backend.md) —
  implement the `AshPPlan.Reactor.Durable.Store` behaviour and qualify it with
  the generated conformance suite.

## Reference — information-oriented

Accurate descriptions of the machinery, looked up while working.

- [Public API](reference/public-api.md) — the public modules and functions:
  descriptors, compiler, FOND, durable engine, receipts, evidence exports.
- [CLI and release gate](reference/cli-and-release-gate.md) — the `bin/`
  scripts (`conform`, `conform-falsify`, `manufacture`, `verify-package`,
  `receipt`) and the ten-step exact-head release gate.
- [Ontology and shapes](reference/ontology-and-shapes.md) — `ontology.ttl`,
  the `ontology/shapes.ttl` SHACL conformance profile, and the generated
  catalogs they manufacture.

## Explanation — understanding-oriented

Discourse about design rationale: why the package is shaped the way it is.

- [Architecture and fences](explanation/architecture-and-fences.md) — why a
  control plane and not a fourth workflow engine; why ontology-first with
  generated projections; the descriptor, SELECT/CONSTRUCT/DO, durable-store
  and public-contract laws.
