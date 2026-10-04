# Docs Lint Fix Receipt 2026-10-04

Fix lane for `receipts/docs-lint-2026-10-04.md`. Scope: lane-owned docs only. No git operations.
Not touched (generated, fixed at template): the 8 `docs/jira/ECO-*.md` files, including the
`ECO-SEMANTIC-GATE-WITNESS.md` H1 FAIL from the lint receipt.

## H1 vs filename fixes (4 of the 5 lint FAILs; the 5th is the generated ECO file)

| file | before | after |
|---|---|---|
| docs/jira/coverage-index-2026-10-04.md | `Coverage Index — 2026-10-04 (W25 wave)` | `Coverage Index 2026-10-04` |
| docs/pplan-w3c-audit-2026-10-04.md | `W3C-Style Conformance Audit: ash_pplan Process Semantics (P-PLAN / PROV-O Perspective)` | `PPLAN W3C Audit 2026-10-04` |
| docs/diataxis/reference/public-api.md | `Public API reference` | `Public API` |
| receipts/alignment-wave-2026-10-04.md | `Alignment Wave Receipt — 2026-10-04` | `Alignment Wave 2026-10-04` |

Already conforming (unchanged): `docs/gcp-lifecycle-simulation.md` (`GCP Lifecycle Simulation`),
`README.md` (`ash_pplan`; PASS per lint receipt as project README), `docs/whats-new-2026-10-04.md`
(normalized `What's New — 2026-10-04` → `What's New 2026-10-04` to match the em-dash-free
convention). Predicate used: `kebab-case(H1 minus punctuation/spaces) == filename stem`.
Post-fix verdicts on all 7 owned files: PASS (README by the project-README convention recorded in
the lint receipt).

## Long lines (>100 chars), before → after

| file | before | after | remaining exemption |
|---|---|---|---|
| README.md | 61 | 4 | 4 table rows (durable-run/capability tables); wrapping would break tables |
| docs/pplan-w3c-audit-2026-10-04.md | 31 | 20 | 16 findings-index table rows + 4 fenced-code lines (shell/elixir) |
| docs/diataxis/reference/public-api.md | 75 | 46 | 46 API table rows; table structure left intact per task |
| docs/jira/coverage-index-2026-10-04.md | 38 | 38 | all table rows, exempt per its disclosed deviation |
| docs/gcp-lifecycle-simulation.md | 0 | 0 | — |
| receipts/alignment-wave-2026-10-04.md | 0 | 0 | — |
| docs/whats-new-2026-10-04.md | 0 | 0 | — |

Prose wrapping method: Python `textwrap` at width 100, `break_long_words=False`,
`break_on_hyphens=False`, hanging indent for list items; fenced code blocks and table rows
skipped. Content preserved (wrap only, no deletion) — verified by insertions ≥ deletions in
diff and zero rewrites of inline content.

## Post-fix lint

- Long-line violations in owned files: 205 → 108 (all 108 are table rows or fenced code).
- Prose long lines outside fences/tables: **0** across all 7 owned files.
- H1/filename: all 7 owned files PASS; remaining lint FAIL is the generated
  `ECO-SEMANTIC-GATE-WITNESS.md`, which fixes at the semantic-jira template, not per-file.
- Broken relative links: unchanged (0), no link lines were wrapped.
