# Gate Receipt: GCP Lifecycle Plan Court — 2026-10-04

## Verdict: GREEN (as-is, no fixes required)

The three failures flagged by earlier ERRC reporting (27-vs-29 variable count,
tape-not-8-steps, anti-vacuity edge) do NOT reproduce on the current tree.
The bridge lane's fixes are present and holding.

## Command

```
cd /Users/sac/ash_pplan
MIX_BUILD_ROOT=_build-gcpcourt mix test test/courts/gcp_lifecycle_plan_court_test.exs
```

Fresh build root (`_build-gcpcourt`, full recompile of ash_pplan + deps).

## Output tail

```
Running ExUnit with seed: 688607, max_cases: 32

........
Finished in 0.5 seconds (0.00s async, 0.5s sync)
8 tests, 0 failures
```

## Assertion state on disk (test/courts/gcp_lifecycle_plan_court_test.exs)

- Variable count pinned to `== 29` (line 181), with comment at line 180:
  "29 in the canonical TTL (the brief said 27 — the file is ground truth)."
- Tape/chain assertions pin exactly 8 steps, chain unfolded 1→2→…→8
  (`map_size(steps) == 8`, `unfold(head, edges, 8)`), matching Runtime
  execution reality.
- Anti-vacuity edge test present (precedence-free plan must genuinely fail).

## Resolution

Earlier ERRC report is STALE. Current state = 8/8 green with 29-variable pin,
matching the bridge lane's report. No edits made to the court test.
