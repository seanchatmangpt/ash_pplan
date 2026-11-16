# ash_pplan migration plan v26.11.16

Standing: UNVERIFIED

## Identity
- Path: /Users/sac/ash_pplan
- Remote: https://github.com/seanchatmangpt/ash_pplan.git
- Branch@sha: main @ b7da529 (tracks origin/main, ahead 0 / behind 0)
- Last commit: 2026-11-13; commits: 438; size: 2903 MB
- Languages/build: Elixir (mix.exs, mix.lock), ggen.toml, ontology.ttl, docker/
- Nested repos: none

## Observed state
- Dirty: 13 modified (README.md, bench/*.md, bench/claims_bench.exs, docs/*.md,
  docs/diataxis/reference/*, docs/jira/v26.11.10/ECO-HEX-PUBLISH-READINESS.md)
- Untracked: 59 paths, grouped: `.claude/`, `bench/baseline_runner.exs`, `docs/MIRROR-SIM*.md`,
  `docs/jira/v26.11.12/`, `docs/jira/v26.11.15/`, `scripts/mirror_sim/`, `test/mirror_sim/`,
  `test/support/mirror_sim/`
- Stash: 318 entries (census) -- very large stash history
- Unpushed local branches: 4 (`fix/dsl-docs-unbackticked-spec-cells` has no upstream;
  `feat/frontier-evidence-v1` ahead 1; others tracked)
- Build/dep dirs: `_build` 374M, `_build_test` 426M, `_build-bench` 381M, `_build-coord` 383M,
  `_build-mirror` 383M, `deps` 451M (~2.4 GB of 2.9 GB is rebuildable)
- Stray artifacts: `ash_pplan-26.11.10.tar` (864K), `erl_crash.dump` (4.8M),
  `tmp_93F942...` dir, `tmp/`, `checkpoints/`, `receipts/`
- Submodules: none

## What it is
P-PLAN/PROV-O semantics projected into an Ash-native process control plane: hierarchical process
representation, FOND policy validation, Reactor outcome observation and a native durable run
ledger on top of Ash/Reactor/AshStateMachine. Hex-published library.

## Classification
ACTIVE (census agrees; last commit 3 days ago, two unlanded jira dirs v26.11.12 / v26.11.15).

## Migration risk
HIGH. Would lose: 13 modified docs/bench files, the entire mirror_sim lane (scripts/test/docs,
untracked), two jira dirs (v26.11.12, v26.11.15), 318 stashes, 1 branch with no upstream,
1 branch ahead by 1. Local-only data: `checkpoints/`, `receipts/`, `release-receipt.json`,
`erl_crash.dump` (diagnostic, disposable).

## Recommended action
COMMIT-PUSH
1. `git -C /Users/sac/ash_pplan add -A && git commit -m "preserve(v26.11.16): mirror_sim lane + jira v26.11.12/15"`
2. `git -C /Users/sac/ash_pplan push origin main`
3. `git -C /Users/sac/ash_pplan push origin fix/dsl-docs-unbackticked-spec-cells feat/frontier-evidence-v1`
4. DECISION: 318 stashes. Either discard, or archive once:
   `git -C /Users/sac/ash_pplan bundle create /Volumes/ARCHIVE/ash_pplan-stashes.bundle --all`
   (bundle includes refs/stash tip only; for all stashes export with `git stash list` + `git show`).
5. Cleanup before any copy:
   `rm -rf _build _build_test _build-bench _build-coord _build-mirror deps erl_crash.dump tmp tmp_93F942*`
6. DECISION: keep or delete `ash_pplan-26.11.10.tar` (release tarball, reproducible from tag).
7. New machine: `git clone https://github.com/seanchatmangpt/ash_pplan.git`.

## First commands on the new machine
`mix deps.get && mix compile --warnings-as-errors && mix test` (stated, not run).

## See Also
- ../v26.11.15/ (previous jira dir), ../v26.11.12/, ../v26.11.10/
- /Users/sac/docs/jira/v26.11.16/README.md (master index)
