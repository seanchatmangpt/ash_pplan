---
name: mirror-sim-gate
description: Coordinator gate ladder for the ash_pplan mirror simulation server. Use after mirror-sim lanes land, before committing.
---

# mirror-sim-gate

Run in order, real output, from /Users/sac/ash_pplan:
1. `MIX_ENV=test mix compile --warnings-as-errors`
2. `mix format --check-formatted` (fix listed files explicitly)
3. `MIX_ENV=test mix test test/mirror_sim` (use `MIX_BUILD_ROOT=_build-mirror` to isolate)
4. `grep -rEn "Mox|:meck|Process.sleep" test/support/mirror_sim test/mirror_sim` -> zero matches
5. `bash scripts/mirror_sim/run_all.sh` -> receipts/mirror-sim-<sha>.md
Commit explicit paths with `git commit -F <file>`; verify with `git ls-remote | grep $(git rev-parse HEAD)`.
Delete `_build-mirror*` roots before the final commit.
