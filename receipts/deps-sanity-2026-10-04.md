# deps-sanity receipt — 2026-10-04

Subject: /Users/sac/ash_pplan @ main, working tree (uncommitted post-churn state, HEAD 9a89aac).
Scope: read-mostly lane; only this file written. No git operations.

## Checks

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | `mix deps.get` → no changes | PASS | exit 0; idempotency proven: sha256(mix.lock) identical before/after second `mix deps.get` run (`ad2dbc90c0bf5442...`). Note: `git diff mix.lock` vs HEAD is non-empty (13 added lines), but that delta pre-existed this session (mix.lock was already `M` in the session-start git status) — deps.get itself changed nothing. Added-vs-HEAD lines are ex_doc 0.40.4, earmark_parser 1.4.46, cc_precompiler 0.1.11, elixir_make 0.10.0, fine 0.1.6 + transitives — consistent with the ex_doc dep added in commit 31626c9. |
| 2 | `mix deps.unlock --check-unused` | PASS | exit 0, empty output (no unused deps reported). |
| 3 | `mix hex.audit` | PASS | "No retired or security advisory packages found", exit 0. |
| 4a | `grep petal_components mix.lock` | PASS | hex pin `petal_components 2.9.3` present, sha256 `1fb005eb82fe3cc755310c31bb2fa995fd209295b829f38e0bae31fea351e4e3`. |
| 4b | `grep petal_framework mix.lock` | PASS (absent) | grep exit 1, zero matches — petal_framework gone. |
| 5 | `mix deps.tree` wiring | PASS | `├── petal_components ~> 2.8 (Hex package)` and `├── reactor_process (vendor/reactor_process)` — hex petal_components and path dep reactor_process wired at app root as intended. |
| 6 | `MIX_BUILD_ROOT=_build-depsan mix compile --warnings-as-errors` | PASS | exit 0; `Compiling 151 files (.ex)` / `Generated ash_pplan app`, zero warnings. Log: /tmp/depsan_compile.log. |

## Result

6/6 PASS. Dependency state is sane after the petal_components hex swap, lock pruning, and
earmark resolution. `_build-depsan` deleted (confirmed absent). No fixes made; nothing to
escalate to another lane.

## Falsifier

Any of the six checks returning nonzero, a mix.lock mutation by deps.get, petal_framework
reappearing in mix.lock, or a compile warning under `--warnings-as-errors` would refute
this receipt. None observed.
