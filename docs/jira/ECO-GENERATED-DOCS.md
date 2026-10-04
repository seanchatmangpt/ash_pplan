# ECO-GENERATED-DOCS: `documentation/` keep-tracked vs ignore

Decision: **IGNORE** — treat `documentation/` as a generated build artifact.
Date: 2026-10-04 · Lane: group E (commit-grouping open question)

## Decision rule applied

Nothing reads it and it is regenerable via `mix docs` → ignore.

## Evidence

1. **Tracked status**: `git ls-files documentation/ | wc -l` = **0**. The directory
   was never tracked; no `git rm --cached` plan is needed (nothing to untrack).
   On disk it contains only Spark/ex_doc DSL output:
   `documentation/dsls/DSL-AshPPlan.Dsl.PPlan.md`,
   `documentation/dsls/DSL-AshPPlan.Workflow.md`.
2. **Generator**: `mix.exs:90` declares `{:ex_doc, ">= 0.0.0", only: :dev, runtime: false}`;
   no bin/ script references `documentation/`. ex_doc/Spark writes DSL docs into
   `documentation/dsls/` on `mix docs`. Regenerable on demand.
3. **Readers**: `grep -rn "documentation/" test/` = zero matches. No court or test
   reads the directory.
4. **History/convention**: `git log -- documentation/` = empty (never committed).
   README.md and CHANGELOG.md contain no `documentation/` path references.
   The curated human docs live in `docs/` (which IS tracked and listed in
   `mix.exs:113` tool coverage list); `documentation/` is a separate, machine-only
   surface.

## Actions

- `.gitignore`: appended `/documentation/` (verified with `git check-ignore -v` →
  `.gitignore:32:/documentation/ documentation/`). Applied this lane.
- Uncommitted-state implication: `documentation/` currently shows as `??` untracked;
  after the ignore entry lands it disappears from `git status` output entirely.
  No `git rm --cached` is required since the path was never tracked — if a future
  commit ever tracks it, the untrack command would be
  `git rm -r --cached documentation/ && git commit -F <msg-file>` (coordinator only).

## Falsifier

A test, bin/ script, or published artifact that reads `documentation/` paths, or a
deliberate decision to publish DSL docs from the repo, invalidates the ignore
decision and requires reverting the `.gitignore` line.
