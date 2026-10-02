# Publish checklist — ash_pplan 26.10.2 (CalVer, 2026-10-01)

## Identity

- Version: 26.10.2 (hex API: no published release exists for ash_pplan — 404; 26.10.2 free)
- HEAD at packaging: main `b80ce69495911081d13f1b87fd2eee55a595d32f` (pushed to origin/main)
- mix.exs `@version "26.10.2"`, `AshPPlan.version()` == "26.10.2", ontology.ttl `owl:versionInfo "26.10.2"`,
  ecosystem.lock.toml `release = "v26.10.2"`

## Verification ladder (all real runs, this session)

| step | command | exit | result |
|---|---|---|---|
| 1 | `mix deps.get --check-locked` | 0 | green (ggen_igniter 26.9.31 from hex) |
| 2 | `mix hex.audit` | 0 | green, no retired/advisory packages |
| 3 | `mix format --check-formatted` | 0 | green on the release content (other lane's in-flight files excluded — see "Known in-flight" below) |
| 4 | full `mix test` | — | 1257 tests: version/contract failures fixed and re-verified targeted (42 tests, 0 failures); manufacture court file 7 tests 0 failures (753s). Residual failures at last full run were a concurrent lane's in-flight FOND/standing-bridge edits (compile error, ActionRunTest refusals) — that lane's tree state, not release content |
| 5 | `./bin/verify-package` | 0 | "package ash_pplan-26.10.2 compiles from its own contents" |

Mutation court (D1's fix) verified standalone: `mix test test/manufacture_test.exs` → 7 tests, 0 failures (752.9s). The regeneration test previously timed out at the 60s default; bounded at 900s (`@tag timeout: 900_000`), now passes in ~5s warm.

## Package checksum

```
8f15b833bc6dc49d2080fe80ec208b26099e83608f0b979b758f32248af17a54  ash_pplan-26.10.2.tar
```

## User-gated step (NOT executed)

```
mix hex.publish
```

Never run by an agent; the user runs `MIX_BUILD_ROOT=_build-p1 mix hex.publish` (or re-runs `./bin/verify-package` first) to publish 26.10.2.