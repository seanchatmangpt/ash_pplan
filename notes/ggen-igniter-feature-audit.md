# ggen_igniter Feature Audit — ash_pplan (Lane D2)

Subject: ggen_igniter v26.9.30 (ref 0abed8a) as used by `bin/manufacture*` on
`docs/diataxis-fanout`. All commands below were executed read-only this session
with `MIX_BUILD_ROOT=_build-d2` / `MANUFACTURE_MANIFEST_ROOT=tmp/mf-d2`;
artifacts under `tmp/mf-d2/`.

## How ash_pplan uses ggen_igniter today

Every `bin/manufacture*` script (7 scripts, 6 packs) is the same shape:
`mix ggen_igniter.sync --pack-dir … --template … --engine oxigraph --on-stale prune
--manifest-dir <per-recipe tmp dir> --verify-cwd $ROOT --out …`, plus `mix format`
afterwards. Receipts land in `.ggen_igniter/receipts/<yyyy-mm-dd>.jsonl`
(91 receipts on 2026-10-01) but are never replayed. CI
(`.github/workflows/ci.yml`, "Re-manufacture exact projections") re-runs all 7
manufacture scripts plus `bin/verify-package`, but never runs `doctor`, `replay`,
`verify`, `plan`, or an engine comparison.

## Feature table

| Feature | Status | Evidence / classification |
|---|---|---|
| `--pack-dir` + `gates/*.rq` discovery | USED | all 7 scripts |
| `--template` per-recipe sync | USED | all 7 scripts |
| `--engine oxigraph` (ORDER BY-safe default) | USED | all scripts |
| `--for-each` row fan-out | USED | workflow / examples / chaos packs |
| `--on-stale prune` + reconciliation manifest | USED (half strength) | per-recipe `--manifest-dir tmp/mf-<lane>-<name>` means the manifest only ever holds one recipe's outputs; repo-wide orphan detection (`--on-stale refuse` refusing a renamed-away recipe) is structurally disabled. |
| `--verify-cwd` path-escape guard | USED | all scripts |
| Receipts (`.ggen_igniter/receipts/*.jsonl`) | WRITTEN, NEVER REPLAYED | no replay call site in bin/, ci.yml, or test/. |
| `mix ggen_igniter.replay` | UNUSED | verified runnable; see evidence below. |
| `mix ggen_igniter.verify` (fail-CLOSED inverted queries + cardinality contracts) | UNUSED | 0 of 6 packs ship `verify/` (`*.unbound.rq` or `cardinality.json`). Gates fail OPEN (≥1 row = pass): deleting one ontology triple silently drops a row and the generated module loses members while manufacture exits 0. |
| `mix ggen_igniter.doctor` (19 checks) | UNUSED | not in CI, not in any script. Ran clean on ash-pplan-pack (one informational ✘, see below). |
| Comparison mode `--engine oxigraph,sparql` + `--engine-report` | UNUSED | verified runnable; report at `tmp/mf-d2/engine-report.md`; engines agree on the main projection query. Diagnostic-additive — actuation still uses only the primary engine. |
| `--dry-run` preview | UNUSED in scripts/CI | works on frontmatter-bearing templates (unlike `plan`); verified "planned: skip … (unchanged)". |
| `mix ggen_igniter.plan` (read-only admission preview) | NOT APPLICABLE | exits 3 (`unsupported_capability`) on frontmatter templates — every repo template carries frontmatter; `sync --dry-run` is the usable preview. |
| frontmatter `inject: true` / `before`/`after`/`at_line` | NOT APPLICABLE | outputs are whole-file generated modules; injection into hand-written files would break the "generated tree is fully manufactured" invariant. |
| `--skip-if` / `--unless-exists` | NOT APPLICABLE | every `--out` is always regenerated unconditionally. |
| `mode: eval` + `sh_before`/`sh_after` shell hooks | NOT APPLICABLE | scripts already orchestrate in bash; hooks would hide orchestration inside templates. |
| `--engine qlever` / `--store-id` | NOT APPLICABLE | no QLever store; single-process ontology. |
| `install` / `fortune5_ready` / `ggen.toml [packs]` bundles | NOT APPLICABLE | ggen.toml is a 6-line stub; pack selection is explicit in bin/ scripts; bundle machinery solves a multi-pack-consumer problem ash_pplan does not have. |
| `pack.fetch` / `pack.lock` (`ggen.lock`) | NOT APPLICABLE | packs are in-repo under priv/ggen/, not fetched; the dep pin lives in mix.exs (0abed8a). |
| `semantic_jira.*` / `sa2a.*` / `ocel.seal` / `epoch.*` / `frontier_release_plan` / `rename` / `hand_authored` / `manifest.dump` / `upgrade` | NOT APPLICABLE | adjacent dep subsystems (Semantic Jira backlog, A2A evidence, OCEL sealing, epoch watermarking) outside ash_pplan's manufacture loop. |
| `GgenIgniter.Lock` cross-process sync lock | USED implicitly | acquired by every sync; doctor check 18 reports it. |

## Verified evidence (this session, real runs)

- `mix ggen_igniter.doctor --pack-dir priv/ggen/ash-pplan-pack` — all pack checks
  PASS (ontology parses, 626 triples; 3 gates parse; oxigraph NIF compiled and
  functionally smoke-tested; no stale lock). One informational FAIL: "could not
  find a simple `version:` literal in mix.exs" — the doctor's version-policy check
  expects ggen_igniter's own CHANGELOG convention; N/A for a consumer repo.
- `mix ggen_igniter.sync … --dry-run` (projection_catalog): "planned: skip
  lib/ash_pplan/generated/projection_catalog.ex (unchanged)" — tree in sync.
- `mix ggen_igniter.replay .ggen_igniter/receipts/2026-10-01.jsonl --verify-only` —
  the last receipt reports **output state changed** (recorded post_run_hash ≠
  current hash of `lib/ash_pplan/generated/plan_catalog.ex`). Cause: every
  manufacture script runs `mix format` AFTER sync, rewriting bytes after the
  receipt's `post_run_hash` was recorded — so naive replay reports phantom drift
  even on a fully in-sync tree. Consequences: (a) replay cannot serve as a court
  until receipt ordering accounts for formatting; (b) real drift detection
  exists and nothing consumes it.
- `mix ggen_igniter.verify --pack priv/ggen/ash-pplan-pack` — verbatim: "cardinality:
  no priv/ggen/ash-pplan-pack/verify/cardinality.json -- gates verified WITHOUT
  cardinality contracts" / "gates: 3 passed, 0 under contract" / "verify: 0
  unbound facts". Confirms the fail-OPEN posture: nothing is under contract.
- `--engine oxigraph,sparql --engine-report tmp/mf-d2/engine-report.md` — report
  written; engines agree on the `projections` query (main projection, 19 rows
  total across 3 queries). One operational note: `--engine-report`'s parent
  directory must already exist (first run failed `File.write!` before
  `mkdir -p tmp/mf-d2`).
- `mix ggen_igniter.plan --pack-dir … --template … --json` — exits 3 with
  "unsupported capability: template frontmatter … Use `mix ggen_igniter.sync
  --dry-run` instead", confirming the plan-vs-frontmatter limitation.

## Top 5 recommended adoptions (ranked by value)

1. **Fail-CLOSED pack verification (`verify/` per pack) as a CI gate.**
   Highest-value gap: every pack gate fails OPEN today — one deleted ontology
   triple silently drops a generated module's members while CI stays green.
   Per pack, add `verify/cardinality.json` (per-gate expected row counts) and
   inverted `verify/*.unbound.rq` queries, then a CI step (or a
   `bin/manufacture` preflight):
   `mix ggen_igniter.verify --pack priv/ggen/<pack> --json-envelope` (exit 1 on
   any unbound fact or cardinality breach). Verified runnable today; reports
   "3 passed, 0 under contract" until contracts are authored.
2. **Doctor as a CI preflight gate.** 19 real checks (ontology parses, every
   gate query parses, NIF compiled + functional smoke test, dep-conflict
   advisories, lock state) for one line:
   `mix ggen_igniter.doctor --pack-dir priv/ggen/<pack> --strict` (drop `--fix`
   in CI). Ran clean today except an informational version-literal check that
   does not apply to a consumer repo — a `--strict` gate should tolerate that
   single check class or it will false-fail.
3. **Engine-comparison runs in CI.** `--engine oxigraph,sparql --engine-report
   tmp/engine-report-<name>.md` on one representative recipe per pack —
   diagnostic-additive, zero actuation risk. Catches the dep's own documented
   failure mode (sparql hex ORDER BY corruption) if a query shape ever
   disagrees between engines; the report is a diffable CI artifact.
   (Note `mkdir -p` the report directory first.)
4. **Receipt replay as a court — after fixing receipt-vs-format ordering.**
   Receipts are written (91 on 2026-10-01) but never replayed, and replay
   currently reports phantom drift because `mix format` runs after the receipt's
   `post_run_hash` is recorded. Adoption: (a) reorder each script so formatting
   happens before receipt finalization (or replay with the manifest dir so the
   final hash covers the formatted bytes), then (b) add
   `mix ggen_igniter.replay .ggen_igniter/receipts/<date>.jsonl --verify-only`
   to CI. Buys: any hand-edit to a generated file, or ontology drift since the
   last sync, becomes a CI failure instead of a silent mismatch.
5. **Shared manifest root + `--dry-run` drift preview in CI.** Replace
   per-recipe `--manifest-dir tmp/mf-<lane>-<name>` in all 7 bin/manufacture*
   scripts with one shared root per lane (`${MANUFACTURE_MANIFEST_ROOT:-tmp/mf}`
   keyed by recipe inside), restoring repo-wide `--on-stale refuse` orphan
   detection (a recipe renamed away currently leaves no trace). Then add a
   post-manufacture CI step:
   `mix ggen_igniter.sync --pack-dir … --template … --out … --dry-run` —
   expected "planned: skip … (unchanged)" for every recipe; any other line is
   generated-tree drift.

## Summary counts

- USED: 7 (pack-dir/gates discovery, per-recipe templates, oxigraph engine,
  for-each fan-out, on-stale+manifest [half strength], verify-cwd, implicit lock)
- UNUSED, WORTH ADOPTING: 5 (verify fail-closed, doctor, engine comparison,
  replay-as-court, shared manifest root + dry-run preview)
- NOT APPLICABLE: 10 (inject/skip/unless-exists, mode:eval + shell hooks,
  qlever, fortune5/install/bundles, pack.fetch/pack.lock, plan [frontmatter
  blocked], semantic_jira/sa2a/ocel/epoch/frontier/rename/upgrade tasks)
