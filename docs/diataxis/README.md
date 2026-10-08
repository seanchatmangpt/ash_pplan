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

- [Serve a run to a remote A2A agent](how-to/a2a-facade.md) — start-or-adopt
  and signal-resume a durable run through `AshPPlan.A2A.Facade`, and read
  its ash_pplan-status → A2A-task-state mapping.
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
- [Adopt a marketplace pack](how-to/adopt-a-marketplace-pack.md) — vendor a
  ggen-marketplace pack's ontology and gates at file level with a sha256 lock,
  or ship a merged-ontology pack.
- [Run the ggen gates](how-to/run-the-ggen-gates.md) — the fail-closed
  verification surface: `bin/ggen-doctor`, `bin/ggen-verify`,
  `bin/ggen-replay-court` (+ `--dry-run-preview`), and `bin/ggen-engine-report`
  (incl. `--graphlaw`); what each gates and when it fails.
- [Run the Tokyo depeg burn-in](how-to/run-the-tokyo-burn-in.md) — run the
  flash-depeg scenario suite (`mix test test/tokyo_depeg`), the TDB stress
  benchmark, reading the five-field receipts, and what each refusal class
  (`REFUSED_AUTHORITY_REVOKED`, `REFUSED_NO_SUCH_RUN`, the conformance and
  SA2A codes) means.

## Reference — information-oriented

Accurate descriptions of the machinery, looked up while working.

- [Public API](reference/public-api.md) — the public modules and functions:
  descriptors, compiler, FOND, durable engine, receipts, evidence exports.
- [CLI and release gate](reference/cli-and-release-gate.md) — the `bin/`
  scripts (`conform`, `conform-falsify`, `manufacture`, `verify-package`,
  `receipt`) and the ten-step exact-head release gate.
- [Vendor pinning](reference/vendor-pinning.md) — the `priv/ggen/vendor/`
  sha256 lock over the ggen-marketplace packs, the `sync.sh` pin gate
  (typed exit-3 refusal), and the lawful re-pin procedure with the
  a39971f worked example.
- [Ontology and shapes](reference/ontology-and-shapes.md) — `ontology.ttl`,
  the `ontology/shapes.ttl` SHACL conformance profile, and the generated
  catalogs they manufacture.
- [Generated reference](reference/generated/README.md) — doc-hdit-scaffolded
  reference skeletons for every `lib/` module, grouped by namespace, with
  per-module source links, SHA256 prefixes, and DEGENERATE markers for
  `@moduledoc false`/missing moduledocs.

## Explanation — understanding-oriented

Discourse about design rationale: why the package is shaped the way it is.

- [Architecture and fences](explanation/architecture-and-fences.md) — why a
  control plane and not a fourth workflow engine; why ontology-first with
  generated projections; the descriptor, SELECT/CONSTRUCT/DO, durable-store
  and public-contract laws.
- [Standing, receipts, and the ladder](explanation/standing-receipts-and-the-ladder.md) —
  the three standing layers, `Standing.verdict/3` and `Standing.receipt/2`,
  and the broken-layer to broken-term mapping.
- [Process evidence and OCEL](explanation/process-evidence-and-ocel.md) —
  `ProcessEvidence` events from a receipt, `LedgerOCEL` export and digest of a
  durable run, and the guarded ex4pm adapter.
- [Tokyo depeg burn-in](explanation/tokyo-depeg-burn-in.md) — why the
  flash-depeg scenario is staged as identity, fencing, conformance,
  revocation, receipt, and actuation-boundary courts.
- [Cross-repo vocabulary](explanation/cross-repo-vocabulary.md) — who owns
  the OCEL kernel (xaas; four dialects found, ash_pplan's envelope closest
  to spec), which receipt schema is canonical (ggen's portable envelope as
  evidence format, DfCM v2 as the R vocabulary), and why
  `lib/ash_pplan/sa2a/` is an adapter, not a fork; verdicts from the
  2026-10-03 fleet audits.
