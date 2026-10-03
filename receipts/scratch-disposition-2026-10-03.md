# Scratch Dir Disposition Receipt — 2026-10-03 (Plan P8 residue)

Scope: the three scratch dirs named in P8's open-residue decision.

| Dir | Size | Contents | Regenerable | Decision |
|---|---|---|---|---|
| `.clap-noun-verb/` | 8 KB | CLI OCEL telemetry: `ocel.json` (1 failed `sync run` invocation, proc 70507, 2026-10-03T08:51Z) + `receipts.jsonl` (1 line, same event) | Yes — appended by every clap-noun-verb CLI run | **DELETE** (executed) |
| `notes/reclaimed-home/` | 1.0 MB | 21 salvaged home-dir notes (2024-10 .. 2026-09: dogplatform.md 735K, Fortune5/JTBD set, portfolio changelog, SOPs) | **No** — unique hand-written/one-off documents with no generator | **RETAIN ON DISK** (gitignored, no deletion) |
| `priv/ggen/.ggen_igniter/` | 176 KB | `manifest.json` (ggen pack projection map, template→output sha256 bindings) + `receipts/2026-10-03.jsonl` (161 KB reconciliation log, PLAN_CONSTRUCTED 22 files) | Yes — rewritten by every `ggen sync` run (gitignore comment: "manifest + run receipts, regenerated") | **DELETE** (executed) |

## Gitignore verification

All three covered in `.gitignore`:
- line 7: `/.ggen_igniter/`
- line 18: `/.clap-noun-verb/`
- line 19: `/notes/reclaimed-home/`
- line 21: `/priv/ggen/.ggen_igniter/`

Verified via `git status --porcelain`: none of the three appear as untracked.

## Deletion gate

Pre-delete `lsof +D` on all three dirs: **zero open handles** — no running process
referenced any of them. Deletions executed 2026-10-03.

## Test-file check

`test/stress/checkpoint_burst_kill_test.exs` and
`test/tokyo_depeg/actuation_boundary_test.exs`: `git status --porcelain` and
`git diff` both EMPTY — working tree matches HEAD for both. The post-fix versions are
already committed (recent commits: `0a706ef` sa2a Replay hardening, `3d9e039` SubjectGuard
hardening); nothing uncommitted left to verify.
