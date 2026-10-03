# Standing / Closure-Path Baseline — 2026-10-03

BENCH lane. Baseline for the standing/closure hot paths of `ash_pplan` at
commit `dbeddf6` (working tree; no git operations performed in this lane).

- Script: `bench/standing_closure_bench.exs`
- Raw data: `bench/standing_closure_raw1.json`, `bench/standing_closure_raw2.json`
- Harness: mirrors `bench/hot_paths_bench.exs` (warm-up, 7 timed batches,
  ips / mean us / stddev / retained-process memory per op). No new deps
  (no Benchee).
- Env: OTP 28, Elixir 1.19.5, macOS (Darwin 25.2.0), MIX_ENV=test,
  `MIX_BUILD_ROOT=_build-errc8`.

## Reproduce

```sh
MIX_BUILD_ROOT=_build-errc8 MIX_ENV=test \
  mix run bench/standing_closure_bench.exs bench/standing_closure_raw1.json
MIX_BUILD_ROOT=_build-errc8 MIX_ENV=test \
  mix run bench/standing_closure_bench.exs bench/standing_closure_raw2.json
```

## Results — two runs, delta is run2 vs run1

### Standing.receipt/2 by evidence size

| suite | run1 mean us | run2 mean us | delta | run1 ips | run2 ips |
|---|---|---|---|---|---|
| receipt/10 events | 327.2 | 355.0 | +8.6% | 3064.5 | 2819.0 |
| receipt/100 events | 5916.7 | 6110.8 | +3.3% | 169.4 | 163.9 |
| receipt/1000 events | 419802.6 | 448093.9 | +6.7% | 2.4 | 2.3 |

### Standing.ladder/2 by rung depth (promotion stops at rung `depth`)

| suite | stop state | run1 mean us | run2 mean us | delta |
|---|---|---|---|---|
| ladder/depth 3 | VALIDATED (index 2) | 1070.6 | 3300.1 | +208% |
| ladder/depth 6 | ADMITTED (index 6) | 592.0 | 2434.7 | +311% |
| ladder/depth 10 | VERIFIED (index 9) | 1981.1 | 9350.6 | +372% |

### policy_closure: FOND.Synthesis.synthesize/3 (strong-cyclic) + FOND.validate_policy/4

| graph nodes | synth r1 us | synth r2 us | delta | validate r1 us | validate r2 us | delta |
|---|---|---|---|---|---|---|
| 50 | 213.7 | 182.4 | -14.7% | 140.6 | 137.2 | -2.4% |
| 500 | 3138.9 | 5658.1 | +80.2% | 1590.2 | 1424.6 | -10.4% |
| 5000 | 34151.3 | 85329.1 | +150% | 27461.9 | 37386.2 | +36.1% |

### ExecutionReceipt observe + to_rdf (construction+validation) at 1k

| suite | run1 mean us | run2 mean us | delta | run1 ips | run2 ips |
|---|---|---|---|---|---|
| observe_and_to_rdf/1k | 71.0 | 72.3 | +1.9% | 14106.5 | 13849.8 |

## Notes

- Fixtures verified non-vacuous in-script: all receipt fixtures settle at
  `standing=ALIVE`; ladder runs promote exactly to the intended rung
  (VALIDATED / ADMITTED / VERIFIED); each policy fixture yields a valid
  strong-cyclic policy covering all n reachable states
  (|policy| = n-1 on a chain).
- The sealed OCEL ledger digest dominates receipt cost: 10 -> 1000 events is
  327 us -> 420 ms, roughly linear in evidence size.
- `mem_bytes_per_op` is 0.0 for all suites: the hot-path work is transient
  (nothing is retained per op), so the retained-process-memory probe from the
  hot_paths harness measures ~nothing here. Read mean_us/ips.
- Run 2 ladder and policy numbers are inflated by concurrent lane load on the
  same machine (stddev_pct up to 43%); treat the positive run2-run1 deltas on
  those suites as noise bounds, not regressions. Receipt and
  ExecutionReceipt, the tightest suites, moved only +2% to +9% between runs.
- Ladder depth mapping: depth 3 = run without `:execution` (stops VALIDATED),
  depth 6 = run without `:run_id` (stops ADMITTED; the receipt rung refuses
  for missing identity), depth 10 = full run (VERIFIED).
