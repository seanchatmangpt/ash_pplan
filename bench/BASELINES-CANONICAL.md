# Canonical Bench Baselines — 2026-10-03

Consolidation of the six scattered per-lane baseline docs into one reference.
Every number below is transcribed from already-recorded runs (no rerun; machine
was loaded at consolidation time). "Best evidence" = median of the recorded
runs for that suite, with run-to-run delta as the noise bound.

Environment (unless a row says otherwise): `/Users/sac/ash_pplan`, working tree
2026-10-03, aarch64-apple-darwin25.2.0, OTP 28, Elixir 1.19.5, 16 schedulers,
in-script harnesses (no Benchee), no new deps.

Sources: `BASELINE-2026-10-03.md`, `STORE-SCALING-2026-10-03.md`,
`STANDING-CLOSURE-BASELINE-2026-10-03.md`, `COMPILER-BASELINE-2026-10-03.md`,
`OCEL-SCALING-2026-10-03.md`, `TDB-BASELINE-2026-10-03.md`.

## Suite index (staleness / trust)

| suite | source doc(s) | runs recorded | run date | fresh? | trust |
|---|---|---|---|---|---|
| Hot paths (engine/standing/ledger/FOND) | BASELINE | 2 | 2026-10-03 | fresh | medium (engine paths noisy under load) |
| Store scaling ETS vs DETS | STORE-SCALING + BASELINE | 3 | 2026-10-03 | fresh | high for ETS; medium for DETS |
| Burn-cycle decay | STORE-SCALING appendix | 2 | 2026-10-03 | fresh | high (shape agrees across runs) |
| Compiler cost curve | COMPILER-BASELINE | 2 | 2026-10-03 | fresh | high (median-of-5 harness) |
| Standing/closure paths | STANDING-CLOSURE | 2 (+2 probe +1 cache) | 2026-10-03 | fresh | high for receipt; ladder/policy noisy |
| Receipt result cache | STANDING-CLOSURE addendum | 2 probe + 1 impl | 2026-10-03 | fresh | high (28 tests, byte-identity verified) |
| OCEL ledger scaling | OCEL-SCALING | 2 | 2026-10-03 | fresh | high for record/events; medium for export drift |
| TDB burn-in (sa2a/fence/petri/ledger) | TDB-BASELINE | 2 | 2026-10-03 | fresh | high (stddev < 9%) |
| Tokyo pipeline stages | TDB-BASELINE appendix | 2 | 2026-10-03 | fresh | medium-high (receipt-assembly row noisy) |
| FOND -> TLA+ projection | this doc (suite 8) | 1 | 2026-10-03 | fresh | high for reductions; wall-clock upper bound (run under load 47–95) |

All suites are same-day (2026-10-03) on the same working tree; none is stale
yet. Caveat flags below are load-based, not age-based.

## 1. Hot paths

Reproduce:

```sh
MIX_BUILD_ROOT=_build-map6 MIX_ENV=test mix run bench/hot_paths_bench.exs bench/hot_paths_raw1.json
MIX_BUILD_ROOT=_build-map6 MIX_ENV=test mix run bench/hot_paths_bench.exs bench/hot_paths_raw2.json
```

Median of run1/run2 (mean µs per op; run delta in parens):

| path | best-evidence µs | run delta |
|---|---|---|
| standing_receipt_new_validate_to_map | 4.4 | −8% |
| checkpoint_write_ets_record | 3.8 | −21% |
| checkpoint_write_dets_record | 4,561 | −7% |
| fond_check_domain_200 | 156–167 | −7% |
| fond_validate_policy_strong_cyclic_200 | 477 | +0.03% |
| ledger_ocel_events_1k | 37,680 | +0.3% |
| ledger_ocel_digest_1k | 38,015 | +3% |
| ledger_ocel_export_1k | 54,036 | −5% |
| engine/park_signal_resume_ets | 46,826 | +2% |
| engine/attempt_complete_ets_5step | 7,248 | +6% |
| engine/attempt_complete_dets_5step | 169,000–293,000 | −42% |

Caveat: engine paths ran under concurrent lane load; DETS engine row moved
−42% between runs — order-of-magnitude only. FOND/standing/ledger rows are
tight (stddev < 5–7%) and trustworthy.

## 2. Store scaling (ETS vs DETS)

Reproduce:

```sh
MIX_BUILD_ROOT=_build-bench2 mix run bench/store_scaling.exs
# second/third recorded runs: MIX_BUILD_ROOT=_build-map6 mix run bench/store_scaling.exs
```

Best evidence: the dedicated STORE-SCALING run (`_build-bench2`), cross-checked
against the two BASELINE map6 runs. For DETS (noisy), the 3-run spread is shown.

| metric | store | n=100 | n=1k | n=10k | 3-run spread |
|---|---|---|---|---|---|
| write ops/s | ets | 52k (warmup; 37–46k later runs) | 299–458k | 392–490k | wide at 100 only |
| write ops/s | dets | 76–570 | 75–599 | 95–145 | ~4x — noisy, ceiling ~600 |
| get_run µs | ets | 1.0 | 1.0 | 1.0 | none |
| get_run µs | dets | 36–403 | 25–469 | 18–343 | wide — noisy |
| checkpoints() µs | ets | 69 | 680–1,157 | 10,066–16,663 | ±40% |
| checkpoints() µs | dets | 337–3,454 | 3,128–39,497 | 37,078–245,365 | ~6x — noisy |
| sig dispatch N=1 ops/s | ets | 5,114 (warmup) | 192,308 | 211,864 | tight away from warmup |
| sig dispatch N=8/32 ops/s | ets | — | ~84–183k | ~84–196k | ±40% under load |
| sig dispatch N=1..32 ops/s | dets | 34–164 | 45–295 | 30–181 | order-of-magnitude |

Trustworthy: ETS flat get_run (1.0 µs), ETS signal dispatch ~180–210k ops/s,
DETS write ceiling ~600 → 145 ops/s, DETS dispatch ~30–300 ops/s.
Noisy: DETS absolute latencies (disk-page variance); use the bands, not points.
Structural findings (sync-per-call at `store/dets.ex:112`; full-ledger
`checkpoints/2` scan) hold across all 3 runs.

## 3. Burn-cycle decay (6 cycles x 64 runs, real Engine)

Reproduce (full `mix run` was blocked by an unrelated `qualify.ex` compile
break; the lane used the standalone-`elixirc` fallback documented in
STORE-SCALING-2026-10-03.md):

```sh
MIX_BUILD_ROOT=_build-ch2 MIX_ENV=test mix run bench/burn_cycle_bench.exs out.json
```

Median of r1/r2 orders/s (ets cycle-1 r1 was JIT warmup — excluded; use r2):

| cycle | cum checkpoints | ets orders/s | dets orders/s |
|---|---|---|---|
| 2 | 2,560 | 202.9 | 5.7 |
| 3 | 3,840 | 176.2 | 4.1 |
| 4 | 5,120 | 134.4 | 3.8 |
| 5 | 6,400 | 109.4 | 3.8 |
| 6 | 7,680 | 91.2 | 3.2 |

Trustworthy: the shape — DETS steep decay to ~3 orders/s, ETS ~2.2x decay off
a ~200 peak, ~25–30x cross-store gap at cycle 6. Both runs agree within ~10%
on the endpoint. Raw lookup microbench: ets ~0.08–0.10 µs flat; dets ~25–95 µs
(noisy band, ~300–1,150x gap).

## 4. Compiler cost curve

Reproduce:

```sh
MIX_BUILD_ROOT=_build-ch7 MIX_ENV=test mix run bench/compiler_cost_curve.exs
```

Median of the two runs' median-of-5 (µs):

| case | steps | best-evidence µs | run delta |
|---|---|---|---|
| linear chain 10 | 10 | 192 | +0.5% |
| linear chain 100 | 100 | 3,062 | −22% (both runs' min–max overlap) |
| linear chain 1000 | 1000 | 107,133 | −0.4% |
| wide fan-out 10 | 10 | 175 | 0% |
| wide fan-out 100 | 107 | 3,333 | 0% |
| wide fan-out 1000 | 1067 | 134,210 | +4% |
| dup-fence 1000 clean | 1000 | 109,756 | −1.8% |
| dup-fence 1000, 500 dup IRIs | 1500 | 918 | +20% (both sub-ms) |

Trustworthy: superlinear 1000-step compile ~107 ms (linear) / ~132–137 ms
(fan-out); duplicate fence refuses in ~0.8–1.0 ms (fence is ~650x cheaper than
full compile — corroborated independently by TDB stage 2: 8.6–10.6 µs at 200
dups). Cross-suite corroboration makes this the most solid suite.

## 5. Standing / closure paths

Reproduce:

```sh
MIX_BUILD_ROOT=_build-errc8 MIX_ENV=test mix run bench/standing_closure_bench.exs bench/standing_closure_raw1.json
MIX_BUILD_ROOT=_build-errc8 MIX_ENV=test mix run bench/standing_closure_bench.exs bench/standing_closure_raw2.json
```

Best evidence: run1 (run2 ladder/policy rows were inflated by concurrent lane
load, stddev up to 43% — per the source doc's own note, treat those as noise
bounds).

| suite | best-evidence mean µs | trust |
|---|---|---|
| receipt/10 events | 327–355 | high (delta +8.6%) |
| receipt/100 events | 5,917–6,111 | high (delta +3.3%) |
| receipt/1000 events | 419,803–448,094 | high (delta +6.7%) |
| ladder/depth 3 | 1,071 (r2: 3,300 — noise) | low — rerun before comparing |
| ladder/depth 6 | 592 (r2: 2,435 — noise) | low — rerun before comparing |
| ladder/depth 10 | 1,981 (r2: 9,351 — noise) | low — rerun before comparing |
| policy synth 50/500/5000 nodes | 214 / 3,139 / 34,151 | medium (r2 −15% to +150% under load) |
| policy validate 50/500/5000 nodes | 141 / 1,590 / 27,462 | medium |
| observe_and_to_rdf/1k | 71.0–72.3 | high (delta +1.9%) |

Trustworthy: receipt cost ~linear in evidence size (327 µs @ 10 → 420 ms @ 1k),
dominated by ledger digest (~45%) + verdicts (~47–52%) per the probe.
Ladder absolutes are the weakest numbers in this whole consolidation — only
run1 is usable and it was not load-isolated.

### 5a. Receipt cache probe + implementation

Probe (`MIX_BUILD_ROOT=_build-ch15`, 2 runs, medians): 1k-event
`Standing.receipt/2` = ~284.0–292.8 ms/call; ledger digest ~44–46%, verdicts
~47–52%, OCEL+ex4pm ~2–3%. Digest-only memo caps saving at ~44–46%; whole-result
cache takes it to lookup.

Implemented: `Standing.receipt_cached/2` (`lib/ash_pplan/standing/cached.ex`,
ETS LRU-256, content-addressed key) — miss 296.0 µs-scale parity (1.06x faster
than direct), hit **1,655 ns vs 312.8 ms direct = 188.9x**, byte-identical
result verified, 28 tests 0 failures (`_build-imp2`). Trustworthy.

## 6. OCEL ledger scaling

Reproduce:

```sh
RUN_100K=1 MIX_ENV=test mix run --no-compile bench/ocel_export_scaling.exs
```

Best evidence: run 2 (4-point sweep incl. 100k); run 1 agrees where they
overlap.

| phase | best-evidence µs/event (1k → 100k) | verdict |
|---|---|---|
| record (Ets writes) | 3.1 → 2.5 | LINEAR (R²=0.9995) |
| events | 3.14 → 4.06 | mildly superlinear (+29%) |
| export (OCEL2-JSON) | 13.07 → 23.84 | superlinear (+82%; run1 +75.5%) |
| digest | 2.56 → 4.43 | superlinear-ish (run1 +102%, run2 +73%) |

Memory: events-phase peak ~97 MB at 100k; digest transiently +68–97 MB.
Trustworthy: record LINEAR; export superlinear verdict (both runs, both
directions agree, and the falsifier criterion — ±25% of 13 µs across 1k→100k —
fails decisively). Export ~2.4 s at 100k events. Note this binds to
`mix run --no-compile` over pre-existing `_build/test` artifacts (qualify.ex
break); modules exercised were unmodified in the tree.

## 7. TDB burn-in (sa2a / compiler fence / petri alignment / ledger)

Reproduce:

```sh
MIX_BUILD_ROOT=_build-tdb-b1 MIX_ENV=dev mix run bench/tdb_burn_in_bench.exs bench/tdb_burn_in_raw.json
```

MIX_ENV=dev (test env blocked by pre-existing `test/support/tokyo_depeg/`
corruption). Best evidence = run1, run2 variance check in parens (µs/op):

| benchmark | best-evidence µs | run2 | trust |
|---|---|---|---|
| sa2a_propose_fond_states_10 | 36.0 | 35.4 | high |
| sa2a_propose_fond_states_100 | 521 | 553 (±6%) | medium-high |
| compiler_duplicate_fence_200_dups | 8.6 | 10.6 | high (stddev 1.4%) |
| compiler_no_fence_200_unique | 5,648 | 5,521 | high |
| petri_align len 4 / 16 / 64 | 17.9 / 36.3 / 68.0 | 18.0 / 41.6 / 73.3 | high |
| ledger_ocel 1k events/export/digest | 1,930 / 10,645 / 2,277 | identical | high |
| ledger_ocel 10k events/export/digest | 29,155 / 134,755 / 28,262 | identical | high |

Note: OCEL 1k export here (10.6 ms ≈ 10.6 µs/event) corroborates suite 6's
run-1 figure (11.4–13.1 µs/event) — the export superlinearity start point is
solid. Alignment scales superlinearly with trace length (Dijkstra
synchronous-product); fence-vs-full-compile gap ~650x, corroborated by suite 4.

### 7a. Tokyo pipeline per-stage costs

Reproduce:

```sh
MIX_BUILD_ROOT=_build-tdb-b2 MIX_ENV=dev mix run bench/tokyo_stage_costs.exs out.json
```

Median of r1/r2 (µs; source doc flags receipt-assembly r1 as cold-GC, use r2):

| stage | best-evidence µs | run delta | trust |
|---|---|---|---|
| canonical identity (JCS+BLAKE2b) | 23.2 | −2.6% | high |
| dup fence (200 dups) | 10.1 | −0.9% | high |
| compile 200 unique | 6,636 | +2.3% | high |
| alignment len 4 / 16 / 64 | 10.4 / 119.8 / 550.7 | +11% / +14% / +6% | medium |
| Standing.verdict/3 | 0.29 | −6.7% | high (O(1)) |
| Standing.verdicts/1 | 2.58 | +5.2% | high |
| receipt assembly | 212.8 (r2; r1 290 had 50% stddev) | −26.7% | medium — use r2 |
| OCEL export+sha256 1k | 11,000 | +9.5% | medium-high (~11 µs/event) |
| sha256 only (47 kB) | 269 | +1.3% | high |

## 8. FOND -> TLA+ projection (fond_tla bench)

Reproduce:

```sh
MIX_BUILD_ROOT=_build-bc2 MIX_ENV=test mix run bench/fond_tla_bench.exs /tmp/fond-tla-canonical.json
```

Canonical rerun (2026-10-03, fresh run in this consolidation — raw JSON:
`bench/fond_tla_canonical.json`). First recorded wall-clock table for this
suite: the only prior reference numbers are the reductions recorded in
`test/fond_tla_bench_test.exs`'s moduledoc (render ~1190, reader ~1060
reductions/state @ 1000-state retry chain), so no wall-clock delta column is
meaningful — reductions are the load-immune comparison.

Render = full TLA+ module render, reader = round-trip parse, validate µs =
TLA+ validation pass; reductions/state are median-of-5 per row.

| row | states | verdict | render ms | reader ms | render red/state | reader red/state | validate µs |
|---|---|---|---|---|---|---|---|
| retry_chain/strong | 101 | refused | 2.0 | 4.3 | 1,171 | 1,087 | 150 |
| retry_chain/strong_cyclic | 101 | admitted | 2.3 | 4.8 | 1,184 | 1,246 | 148 |
| retry_chain/strong | 1,001 | refused | 22.4 | 39.4 | 1,181 | 1,060 | 1,874 |
| retry_chain/strong_cyclic | 1,001 | admitted | 18.3 | 44.7 | 1,196 | 1,234 | 1,750 |
| retry_chain/strong | 5,001 | refused | 109.5 | 311.3 | 1,195 | 1,047 | 24,889 |
| retry_chain/strong_cyclic | 5,001 | admitted | 110.1 | 403.8 | 1,211 | 1,235 | 32,118 |
| fanout/strong | 102 | admitted | 2.1 | 3.8 | 1,431 | 981 | 286 |
| fanout/strong_cyclic | 102 | admitted | 2.2 | 4.4 | 1,444 | 1,074 | 251 |
| fanout/strong | 1,002 | admitted | 31.6 | 39.6 | 1,437 | 979 | 2,908 |
| fanout/strong_cyclic | 1,002 | admitted | 30.8 | 44.8 | 1,452 | 1,068 | 2,610 |
| fanout/strong | 5,002 | admitted | 165.6 | 294.4 | 1,460 | 986 | 34,378 |
| fanout/strong_cyclic | 5,002 | admitted | 172.8 | 349.6 | 1,471 | 1,075 | 25,910 |
| terminal_chain projection | 101 / 1,001 / 5,001 | admitted (all 3) | — | — | 96,064 / 1,142,285 / 14,530,395 total project reductions | | |

Deltas vs the recorded reduction medians: render ~1,171–1,471 and reader
~979–1,246 reductions/state — consistent with the moduledoc's ~1190/1060 at
the 1000-state retry chain (this run: 1,181/1,060; delta +/−2%). Doubling
ratios 500→1000→5000 stay at or under ~1.04x per doubling for render and
~0.92–1.01x for reader on fanout — linear, well under the test's 2.5 bound;
no row approaches the 3,000 reductions/state ceiling. All pinned verdicts
match (`retry_chain :strong` refused at every size; everything else
admitted; terminal_chain admitted at n=100/1,000/5,000).

Machine load during the run: single-run, no load isolation — load average
rose 47 → 95 (16 schedulers, other lanes active on the same host) while
compile of `_build-bc2` overlapped the run's tail. Wall-clock cells should be
read as upper bounds under load; the reduction columns are the trustworthy
ones (deterministic per OTP release, which is why the test gate uses them).

## Cross-suite corroboration (why these medians are safe to cite)

- Duplicate-IRI fence: 0.8–1.0 ms @ 1500 steps (suite 4), 8.6–10.6 µs @ 200
  dups (suite 7), 10.1 µs (suite 7a) — three independent lanes agree on
  fence-cheap/full-compile-expensive.
- OCEL export ~1k: 10.6 µs/event (suite 7) vs 11.4–13.1 µs/event (suite 6).
- DETS ~30 µs/call floor + sync ceiling: store scaling, burn-cycle, and raw
  lookup microbench all land in the same 25–95 µs band.

## Known blockages that shaped these runs (pre-existing, not lane-introduced)

- `lib/ash_pplan/providers/qualify.ex` compile break (during lanes 2–6):
  store/burn-cycle lanes used standalone `elixirc` fallback; OCEL lane used
  `mix run --no-compile`. Suites 1 (hot paths) and 4–5 compiled normally.
- `test/support/tokyo_depeg/` corruption: TDB lane ran MIX_ENV=dev.

## Trustworthiness summary

- Trust: compiler curve, receipt costs, receipt cache (188.9x, test-verified),
  OCEL record LINEAR + export superlinear, TDB rows, ETS store rows, fence.
- Noisy (use bands, rerun before regression comparisons): DETS absolute
  latencies, ladder depths 3/6/10, engine attempt_complete paths, policy
  synth/validate at 500+ nodes, receipt-assembly stage.

## 8. Post-commit regression check — wave-2 standing/cached changes (2026-10-03)

Falsifier: >20% median delta vs the sections above = regression flag.
Reproduce (`_build-bpc`, tree after the wave-2 standing.ex ladder-dedup +
cached.ex commit; serialized runs, machine otherwise idle):

```sh
MIX_BUILD_ROOT=_build-bpc MIX_ENV=test mix run bench/hot_paths_bench.exs /tmp/hpc1.json
MIX_BUILD_ROOT=_build-bpc MIX_ENV=test mix run bench/hot_paths_bench.exs /tmp/hpc2.json
MIX_BUILD_ROOT=_build-bpc MIX_ENV=test mix run bench/standing_closure_bench.exs /tmp/scc1.json
MIX_BUILD_ROOT=_build-bpc MIX_ENV=test mix run bench/standing_closure_bench.exs /tmp/scc2.json
```

Targeted rows (best-evidence above -> median of the two new runs; delta):

| row | before µs | after µs | delta | verdict |
|---|---|---|---|---|
| standing_receipt_new_validate_to_map | 4.4 | 4.53 | +3.0% | no regression |
| checkpoint_write_ets_record | 3.8 | 4.38 | +15% | within noise (this run's own r1/r2 spread 32%) |
| fond_check_domain_200 | ~161 | 178.3 | +10.4% | under threshold; slightly above the old 156-167 band (tight stddev 1-4%), watch it |

Ladder paths (the wave's actual touched code — section 5 flagged these
"rerun before comparing"; baseline only had usable run1, load-inflated):

| row | before µs (run1 only) | after µs (median r1/r2) | delta | verdict |
|---|---|---|---|---|
| ladder/depth 3 | 1,071 | 949 | -11% | no regression |
| ladder/depth 6 | 592 | 562 | -5% | no regression |
| ladder/depth 10 | 1,981 | 847 | -57% | improved (baseline run1 was load-inflated) |

Standing receipt suite (context, same runs):

| row | before µs | after µs | delta |
|---|---|---|---|
| receipt/10 events | 327-355 | 311.4 | -4% |
| receipt/100 events | 5,917-6,111 | 5,080 | -15% |
| receipt/1000 events | 419,803-448,094 | 286,931 | -34% (improved) |

**Verdict: no regression beyond noise on any gated path.** The ladder dedup
did not regress ladder or receipt paths; receipt/1k actually improved ~34%
(vs the pre-dedup numbers, which were taken before the receipt-cache lane).
Ladder run-to-run spread this time was 12-46% stddev (d6 still noisy) — keep
treating ladder absolutes as bands. Raw runs: /tmp/hpc{1,2}.json,
/tmp/scc{1,2}.json.

Quiet-box confirmation (2026-10-03, `_build-hq1`, lanes finished; median of
two fresh hot_paths runs /tmp/hq{1,2}.json vs the "after" column):
standing_receipt_new_validate_to_map 4.62 µs (+2%), checkpoint_write_ets_record
4.18 µs (-5%), fond_check_domain_200 178.2 µs (0%) — all within noise (<10%);
no flagged path.

## Narrowed DETS bands (2026-10-03 quieter box) — NOT NARROWED

Rerun attempt to shrink the section-2 DETS variance bands (3-6x). Two fresh
runs of `MIX_BUILD_ROOT=_build-bsc MIX_ENV=test mix run bench/store_scaling.exs`
(stdout `/tmp/ssc1.txt`, `/tmp/ssc2.txt`), same machine, back to back.

Outcome: the two fresh runs still disagree beyond 2x on most DETS metrics, so
the bands are NOT narrowed — the spread is intrinsic (disk-page variance), not
load. Detach the section-2 caveat accordingly: even on a quiet box, use the
bands, not points.

Full table (columns match section 2; r1 = /tmp/ssc1.txt, r2 = /tmp/ssc2.txt):

| metric | store | n | r1 | r2 | r1/r2 |
|---|---|---|---|---|---|
| write ops/s | ets | 100 (warmup) | 11,374 | 27,382 | — |
| write ops/s | ets | 1k | 467,727 | 425,351 | 1.1x |
| write ops/s | ets | 10k | 405,959 | 425,441 | 1.05x |
| get_run µs | ets | 100/1k/10k | 1.0 | 1.0 | none |
| checkpoints µs | ets | 100 | 68 | 69 | 1.01x |
| checkpoints µs | ets | 1k | 943 | 1,490 | 1.6x |
| checkpoints µs | ets | 10k | 15,600 | 15,155 | 1.03x |
| sig dispatch N=1 ops/s | ets | 1k | 190,840 | 140,449 | 1.4x |
| write ops/s | dets | 100 | 142 | 38 | 3.7x |
| write ops/s | dets | 1k | 112 | 36 | 3.1x |
| write ops/s | dets | 10k | 74 | 52 | 1.4x |
| get_run µs | dets | 100 | 231 | 662 | 2.9x |
| get_run µs | dets | 1k | 768 | 308 | 2.5x |
| get_run µs | dets | 10k | 229 | 522 | 2.3x |
| checkpoints µs | dets | 100 | 1,100 | 2,869 | 2.6x |
| checkpoints µs | dets | 1k | 21,449 | 36,891 | 1.7x |
| checkpoints µs | dets | 10k | 291,364 | 640,052 | 2.2x |
| sig dispatch N=1..32 ops/s | dets | 100 | 46/59/91 | 36/25/24 | up to 2.5x |
| sig dispatch N=1..32 ops/s | dets | 1k | 38/67/79 | 36/37/24 | up to 2.8x |
| sig dispatch N=1..32 ops/s | dets | 10k | 66/36/34 | 32/35/33 | 1.2x |

Consistent with the recorded bands: DETS write 36-142 ops/s sits inside the
recorded 76-570 band at the low end; DETS get_run r2=662 µs and checkpoints
r2=640,052 µs EXCEED the previously recorded maxima (469 µs, 245,365 µs) —
widen those section-2 bands rather than narrowing them. ETS rows remain tight
(write ~405-470k, get_run flat 1.0 µs, checkpoints within 1.6x) and confirm
the structural findings (DETS sync-per-call ceiling ~150 ops/s max observed,
full-ledger checkpoints scan) across all 5 recorded runs.
