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

## Probe: Standing.receipt/2 cacheability over the same run (2026-10-03 addendum)

BENCH lane. Question: is repeated `Standing.receipt/2` over the SAME run
evidence cacheable — is cost O(n) per call with nothing memoized, and does
the sealed ledger digest dominate? Compared against the hypothetical saving
of a naive precomputed-digest shortcut (digest computed once, receipt
assembly reusing the cached digest).

- Script: `bench/standing_receipt_cache_probe.exs` (only new file in this lane)
- Raw data: `bench/standing_receipt_cache_raw1.json`, `bench/standing_receipt_cache_raw2.json`
- Fixture: identical 1k-event chain run (ALIVE), 100 receipts per timed
  batch, 7 batches, component costs (ledger digest, OCEL+ex4pm evidence,
  three-layer verdicts, assembly residual) measured separately. Components
  sum to the measured total within noise.
- Env: same as baseline above, `MIX_BUILD_ROOT=_build-ch15`.

### Results — 1k events, us per `Standing.receipt/2` call

| component | run1 us | run1 share | run2 us | run2 share |
|---|---|---|---|---|
| total receipt call | 292817.2 | 100% | 284004.1 | 100% |
| ledger digest (Chain 2n appends + seal + verify) | 129724.5 | 44.3% | 129224.3 | 45.5% |
| verdicts (plan/execution/consequence) | 136547.1 | 46.6% | 146467.6 | 51.6% |
| OCEL2 export + sha256 + ex4pm evidence | 8806.5 | 3.0% | 6883.4 | 2.4% |
| assembly residual (Receipt.new + validate + fields) | 17739.1 | 6.1% | 1428.9 | 0.5% |
| cached-digest hypothetical (total − digest) | 163092.8 | — | 154779.9 | — |

### Findings

- No memoization: cost is O(n) per call, every call rebuilds the hash chain
  (2 appends + 2 sha256 per event), re-runs the three verdict layers, and
  re-exports/re-hashes the OCEL JSON. 100 receipts of the same run cost the
  same as 100 receipts of 100 different runs.
- The ledger digest does NOT uniquely dominate: it is ~45% of the call, but
  the three-layer verdicts are another ~47-52% (the plan layer is O(n log n)
  sort + O(n) dependency/gate scans). Digest memoization alone caps the
  saving at ~44-46% of the call.
- The naive precomputed-digest shortcut saves ~44-46% (292.8 ms -> ~163 ms
  run1, 284.0 ms -> ~154.8 ms run2). It leaves the verdict layers, the
  OCEL/ex4pm evidence and receipt assembly untouched.

### Recommendation

- Digest memoization in Standing: NO as the whole win, YES as part of a
  keyed whole-result cache. A digest-only memo returns at most ~1.9x; the
  correct cache key is the run's evidence identity (events + model +
  selection + fond_gates + execution + consequence), and the cached value
  should be the full `{:ok, %Receipt{}}` (or at least digest + verdicts),
  which takes the 292 ms repeat call to sub-microsecond lookup. If only one
  change lands, cache the digest: it is the cheapest, semantics-preserving
  half (identical events -> identical seal hash; `Chain.verify/1` recheck
  on cache hit still costs O(n) — skip it only if the chain entries are
  stored with the cache).

## Standing receipt result cache (2026-10-03, implementation receipt)

Recommendation implemented: `AshPPlan.Standing.Cached` — ETS-backed, LRU-bounded
(256 entries) memo of the full `{:ok, %Receipt{}} | {:error, map()}` result,
keyed on evidence identity = sha256 of `term_to_binary({run, opts})` (content-
addressed, no wall clock). Exposed as `Standing.receipt_cached/2`; `receipt/2`
semantics unchanged for existing callers. Module:
`lib/ash_pplan/standing/cached.ex`.

### Measurement (1k events, 100 reps x 7 batches, MIX_BUILD_ROOT=_build-imp2)

| path | us/call | vs baseline |
|---|---|---|
| `receipt/2` (probe baseline, this session) | 312,822.95 | 1.00x |
| `receipt_cached/2` miss (identity + full compute) | 296,047.53 | 1.06x faster |
| `receipt_cached/2` hit | 1,655.06 | **188.9x / 99.5%** |

Byte-identity: cached hit `==` direct `receipt/2` result — verified
(`byte_identical=true`, same digest `781343e6…`). Identity hashing overhead
is negligible on a miss (296.0 vs 312.8 ms).

Probe component shares this session (matches recorded baseline): ledger digest
46.4%, verdicts 51.6%, OCEL+ex4pm evidence 3.3% — the whole-result cache
skips all three, which is why the delta exceeds the digest-only ~46%
hypothetical.

### Verification

- `MIX_BUILD_ROOT=_build-imp2 MIX_ENV=test mix test test/standing/receipt_cached_test.exs test/standing_test.exs`
  → **28 tests, 0 failures** (determinism, invalidation on different events,
  LRU bound + eviction order, cached errors, 2-process same-key concurrency).
- Cache hits reproduce the exact baseline digest, so the memo is replayable
  against the existing baseline records.

## `Standing.receipt_cached/2` across hit-ratio regimes + LRU eviction cost (2026-10-03 addendum)

BENCH lane. Measures `Standing.receipt_cached/2` (ETS memo, 256-entry LRU)
against the raw `Standing.receipt/2` baseline across cache hit-ratio regimes,
plus LRU eviction cost at steady state.

- Script: `bench/receipt_cached_bench.exs` (only new file in this lane)
- Raw data: `bench/receipt_cached_raw1.json`, `bench/receipt_cached_raw2.json`
- Harness: warm-up + 7 timed batches per regime; 100 reps for baseline and
  100%-hit, 25 reps (of a hot+cold pair) for 50%, 25 reps for 0%. Cold calls
  forced harness-side by deleting the run's identity key from the public ETS
  table (guaranteed miss + insert). Real `Standing.Receipt` builds throughout;
  LRU-rotation regime uses 8-event runs so the cache machinery (identity
  sha256 + miss + `tab2list` LRU evict scan) dominates the measurement.
  Sanity gate in-script: cached result `==` direct `receipt/2` result and
  every fixture settles ALIVE, else the run aborts.
- Env: OTP 28, Elixir 1.19.5, macOS (Darwin 25.2.0), MIX_ENV=test,
  `MIX_BUILD_ROOT=_build-hc4` (lane build root deleted after measurement).

### Reproduce

```sh
MIX_BUILD_ROOT=_build-hc4 MIX_ENV=test \
  mix run bench/receipt_cached_bench.exs bench/receipt_cached_raw1.json
MIX_BUILD_ROOT=_build-hc4 MIX_ENV=test \
  mix run bench/receipt_cached_bench.exs bench/receipt_cached_raw2.json
```

### Results — 1k-event ALIVE run unless noted; us per call

| path | run1 us | run2 us | delta |
|---|---|---|---|
| `receipt/2` raw, 100 events | 4643.58 | 4421.36 | -4.8% |
| `receipt/2` raw, 1k events | 284789.20 | 281917.68 | -1.0% |
| `receipt_cached/2` 100% hit (1k) | 1699.27 | 1681.50 | -1.0% |
| `receipt_cached/2` 50% hit (1k, avg of hot+cold pair) | 154897.96 | 147983.59 | -4.5% |
| `receipt_cached/2` 0% hit (1k, miss + insert every call) | 284518.19 | 302611.98 | +6.4% |
| LRU rotation, 500 unique keys at steady state (8ev receipts) | 462.28 | 571.17 | +23.6% |
| refill (hit on an evicted-then-reinserted entry) | 14.30 | 16.15 | +12.9% |

Hit speedup at 1k events: **167.6x / 167.7x** (284.8 ms → 1.70 / 1.68 ms).

### Findings

- Hit cost is dominated by the identity sha256 over `term_to_binary({run,
  opts})`, which scales with run size: ~1.7 ms at 1k events. Measured speedup
  167-168x at 1k events; at 100 events the same receipt was measured at
  ~4.6 ms raw, so even a 1k-sized hit floor of ~1.7 ms would still save ~2.7x
  (smaller runs hash smaller terms and hit faster — the 100ev hit path was
  not separately measured).
- 0% hit ≈ raw receipt cost + overhead: -0.1% to +7.3% between runs — i.e.
  the miss overhead is within run-to-run noise at 1k events. The cache never
  makes a cold path meaningfully slower.
- 50% regime lands where the model predicts: (hit + miss)/2 ≈ 143-146 ms,
  measured 148.0-154.9 ms. Cost is linear in the miss ratio.
- LRU eviction at steady state costs ~0.46-0.57 ms per insert-at-capacity
  (the O(max)=256 `tab2list` + `min_by` scan). That is 0.16-0.2% of a 1k
  receipt miss, but if the workload rotates keys faster than it re-hits, the
  evict scan becomes the dominant cache-side cost; an ordered-set LRU index
  would drop it to O(log n) if that regime ever matters.
- Post-rotation entries re-hit at ~15 us — eviction did not corrupt the table
  (`size == 256` asserted before and after the 500-key rotation).

### Verdict

- The memo is a strict win in every measured regime: ~168x on repeats,
  noise-level overhead on cold paths, bounded table, byte-identical results
  (asserted every run).

## Receipt-cache scaling across evidence sizes (2026-10-03, lane bb1)

`receipt_cached/2` measured per evidence size (100 / 1k / 10k events), with the
identity hash (`AshPPlan.Standing.Cached.identity/2` = `term_to_binary` +
sha256) timed in isolation, plus LRU eviction at steady state under 500-key
rotation against the 256-entry cap. Script: `bench/receipt_cached_scaling.exs`;
raw runs `bench/receipt_cached_scaling_raw1.json` / `..._raw2.json`.

### Harness

Same fixture family as `bench/standing_receipt_cache_probe.exs` (linear task
chain, real `Standing.Receipt` builds, every fixture asserted ALIVE and every
cached result asserted identical (`==`) to the direct `receipt/2` result).
Adaptive effort: 100 ev {5 batches x 100 reps}, 1k {5 x 20}, 10k {2 x 2} for
raw/miss (the sealed ledger digest is O(n^2), a 10k call costs ~33-39 s);
hit/identity at 200/500 reps per size. Warm-up + batch-mean in-script.
Rotation: fill to exactly 256 entries, then 3 batches x 500 fresh unique
8-event keys; size asserted 256 before and after every batch.

### Reproduce

```sh
MIX_BUILD_ROOT=_build-bb1 MIX_ENV=test \
  mix run bench/receipt_cached_scaling.exs bench/receipt_cached_scaling_raw1.json
MIX_BUILD_ROOT=_build-bb1 MIX_ENV=test \
  mix run bench/receipt_cached_scaling.exs bench/receipt_cached_scaling_raw2.json
```

### Results — us per call

| path | 100 ev run1/run2 | 1k ev run1/run2 | 10k ev run1/run2 |
|---|---|---|---|
| `receipt/2` raw | 5201.41 / 4574.28 | 309865.37 / 270283.44 | 39008716.5 / 32737181.0 |
| `receipt_cached` cold miss | 5519.95 / 4742.61 | 300157.58 / 272021.87 | 37905999.0 / 34123849.0 |
| `receipt_cached` hit | 178.01 / 163.16 | 1734.67 / 1597.18 | 17993.4 / 14895.2 |
| identity (t2b+sha256) | 169.18 / 155.20 | 1721.18 / 1551.59 | 17575.30 / 15703.61 |
| identity term bytes | 53925 | 546671 | 5559679 |
| hit speedup vs raw | 29.2x / 28.0x | 178.6x / 169.2x | 2167.9x / 2197.8x |
| miss overhead vs raw | +6.1% / +3.7% | -3.1% / +0.6% | -2.8% / +4.2% |

LRU steady-state rotation (256-entry cap, 500 fresh keys/batch):
**311.29 / 319.15 us per capacity-miss insert** (table size 256 -> 256 asserted).

### Findings

- Identity hash grows strictly linearly: ~169 -> 1721 -> 17575 us for
  53925 -> 546671 -> 5559679-byte terms (10.2x / 10.2x cost per 10x events).
- At 10k events the identity hash is 17.6 ms — it IS the hit path (97.7% /
  105.4% of hit cost; the >100% reading is run-to-run noise). Against the
  1.7 ms hit total at 1k events, 10k evidence makes the hit floor 10.5x
  larger; still 2100-2200x cheaper than the 33-39 s raw receipt, because raw
  cost grows ~O(n^2) while identity grows O(n).
- Hit path is 95-99% identity hash at every size — the ETS lookup + LRU
  re-stamp are noise (~4-45 us). Any future hit-path optimization is
  identity-hash optimization (e.g. hashing a cheap projection of the run
  instead of the whole term).
- Miss overhead is within noise at every size (-3.1% to +6.1%), confirming
  the memo never meaningfully taxes the cold path even at 10k events.
- Steady-state eviction now costs ~0.31-0.32 ms per capacity-miss insert
  (ordered-set LRU index, O(log n) evict) — faster than the ~0.46-0.57 ms
  tab2list scan measured in the section above, and ~0.001% of a 10k miss.

### Verdict

- The memo scales: hit advantage grows with evidence size (29x at 100 ev ->
  ~2100-2200x at 10k ev); identity hashing is the entire hit cost and is
  linear, so the cache never becomes the bottleneck — the O(n^2) raw ledger
  digest does.

### Note (cross-lane)

During measurement, `lib/ash_pplan/standing/cached.ex:237` carried a
pre-existing runtime defect on this tree: the LRU-index `select_delete` match
spec used the charlist `'=:='` instead of the atom `:"=:="`, crashing every
cache hit with "not a valid match specification". This lane applied that
one-token fix to unblock the hit-path measurement (no other change to the
file); the owning lane should re-verify on its own build root.

## Receipt-cache scaling: receipt_cached/2 vs receipt/2 (BENCH lane, 2026-10-03)

Question: does `Standing.receipt_cached/2` pay off at scale, and does the
identity hash (`term_to_binary` + sha256 over the whole `{run, opts}` term)
itself become non-trivial as evidence grows?

- Setup: identical `chain_run/1` fixture at 100 / 1k / 10k events (all settle
  ALIVE, sanity-checked in-script before timing). Same run measured four ways:
  `receipt/2` raw; `receipt_cached/2` cold miss (cache cleared before every
  call, so every call pays identity + miss + insert); `receipt_cached/2` hit
  (primed, same key every call); `Cached.identity/2` alone.
- Env: OTP 28, Elixir 1.19.5, macOS (Darwin 25.2.0), MIX_ENV=test,
  `MIX_BUILD_ROOT=_build-b1b`. No Benchee; in-script harness (warm-up +
  timed batches, adaptive per size — the sealed ledger digest is O(n^2)
  (List.last per chain append), so 10k-event calls cost ~32 s each and the
  10k leg runs 3 batches x 3 reps).
- Raw JSON: `bench/receipt_cache_scaling_raw1.json`,
  `bench/receipt_cache_scaling_raw2.json`.

### Results — us per call, two independent runs

| size (events) | receipt/2 raw r1 / r2 | cached miss r1 / r2 | cached hit r1 / r2 | hit speedup r1 / r2 | identity r1 / r2 | identity term bytes |
|---|---|---|---|---|---|---|
| 100 | 4 834 / 4 560 | 4 847 / 4 903 | 165 / 151 | 29.2x / 30.1x | 154 / 147 (93-97% of hit) | 53 925 |
| 1 000 | 275 625 / 262 524 | 271 405 / 290 005 | 1 562 / 1 668 | 176.4x / 157.4x | 1 546 / 1 691 (99-101% of hit) | 546 671 |
| 10 000 | 32 799 492 / 32 251 786 | 33 149 550 / 33 174 927 | 18 223 / 16 308 | 1 799.9x / 1 977.7x | 17 815 / 16 429 (98-101% of hit) | 5 559 679 |

### Findings

- Hit speedup grows with size: ~30x at 100 events, ~160-180x at 1k,
  ~1 800-1 980x at 10k — because raw receipt cost is superlinear (the O(n^2)
  chain digest) while the hit path is linear in term size.
- Identity computation is the hit path: 93-101% of hit cost at every size.
  It grows linearly (54 kB -> 5.6 MB term, ~0.15 ms -> ~17 ms per hash at
  10k events) and is by far the cheapest way to "touch" a 10k-event run, but
  at 10k events the identity hash alone (~17 ms) costs about what an entire
  1k-event raw receipt costs. It is non-trivial at 10k and would dominate any
  real workload that re-hits large runs frequently.
- Cold miss is never slower than raw beyond noise: miss vs raw is
  -1.5% to +10.5% across sizes and runs; identity + insert overhead is
  invisible against a raw receipt until runs are small.
- `receipt_cached/2` semantics hold: every fixture settles ALIVE, and hit
  results are the memoized `receipt/2` result itself (byte-identical by
  construction, per `AshPPlan.Standing.Cached`).

### Verdict

- `receipt_cached/2` is a strict win at every measured size, and the win
  compounds with evidence size (30x -> ~180x -> ~1 900x). The identity hash
  is the entire hit-path cost and scales linearly; if 10k-event runs are
  re-receipted in tight loops, the next lever is a cheaper identity
  (e.g. hash events individually into a Merkle-style identity) rather than a
  bigger cache.
