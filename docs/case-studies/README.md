# Case Studies

Process-mining-style case studies for `ash_pplan`: each study runs a real
workflow, mines the durable ledger the same way a process-mining tool (e.g.
Celonis) mines an event log, and reports actions and quantified outcomes with
every number traceable to an artifact on disk.

## Honesty contract

Every case study binds to the repo's evidence discipline (see
`docs/demonstration.md` and `bench/BASELINES-CANONICAL.md`):

1. **No invented metrics.** Every number that appears in a case study must cite
   a receipt, baseline, or test that exists on disk — a `bench/fleet/*.json`
   receipt, a `bench/*_RAW` artifact, a raw JSON in `bench/`, a demonstration
   receipt row in `docs/demonstration.md`, or a passing test file. If a number
   cannot be cited, it is not written.
2. **Numbers carry their artifact, not just the claim.** A citation names the
   file, and where applicable the suite row, run dates, and trust level from
   `bench/BASELINES-CANONICAL.md` (fresh / medium / load-noisy caveats travel
   with the number).
3. **Superseded numbers are marked, not deleted.** When a newer run invalidates
   an older figure, the old figure stays in the study with an explicit
   supersession note, following the CHANGELOG convention (e.g. "superseding
   the stale ~2100-2200x pre-chain-fix scaling figures", CHANGELOG 26.10.3).
   The study says which artifact supersedes which.
4. **SKIP and FAIL are stated, never hidden.** Case studies may cite the
   demonstration receipt's overall verdict as-is (`OVERALL: FAIL — 24 PASS,
   1 FAIL, 0 SKIP` as of v26.10.3). A case study must not imply overall
   success the receipt does not show.
5. **Citations are replayable.** Every cited artifact names how to reproduce
   it (bench command, test file, or `bin/demonstrate`), so a reader can
   re-run the evidence chain themselves.
6. **Run-first.** A case study is a projection of an executed P-PLAN run.
   Every study's numbers must come from a run receipt under
   `docs/case-studies/receipts/` produced by actually executing the workflow
   (standing receipt, chain digest, OCEL export). Studies citing only static
   baselines are RUN-FIRST-PENDING, not landed.

## Evidence chain

Every quantified claim in a case study follows one chain:

```text
 run (mix test / bench / bin/demonstrate)
   -> standing receipt (AshPPlan.Standing.receipt/2 -> Standing.Receipt)
     -> OCEL export (AshPPlan.Reactor.Durable.LedgerOCEL)
       -> digest (content-addressed digest of the exported event log)
```

A run produces observations; the standing layer reduces them to a three-layer
verdict and a receipt; the durable ledger exports the same run as an OCEL 2.0
event log; the export is sealed by a content digest. A case study number is
only admissible if all four links are citable to disk (raw result, receipt,
export artifact, digest line).

## How to add a case study

1. Copy `_template.md` to `<kebab-name>.md`.
2. Fill every section; annotate every number with its source artifact.
3. Add the file to the index below with a one-line description.

## Index

| study | status |
|---|---|
| [order-to-cash](order-to-cash.md) | RUN-FIRST-PENDING |
| [procure-to-pay](procure-to-pay.md) | RUN-FIRST-PENDING |
| [finance-transformation](finance-transformation.md) | RUN-FIRST-PENDING |
| [comparison](comparison.md) | RUN-FIRST-PENDING |
| [roi-model](roi-model.md) | RUN-FIRST-PENDING |
| [corpora](corpora.md) | RUN-FIRST-PENDING |

Status is LANDED only when the study cites a run receipt under
`receipts/`; else RUN-FIRST-PENDING.
