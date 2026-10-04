# ROI Model — What We Can and Cannot Claim (W16)

Status: HONEST DRAFT. No customer data, no revenue numbers, no invented deployments.
Every number below is either read from a file on disk (path cited) or explicitly labeled
`[ASSUMPTION]`. This document exists so that any future ROI claim can be audited against
measured artifacts instead of remembered impressions.

## 1. Evidence classes (Forrester TEI-style, what diligence asks for)

A diligence-grade ROI claim needs, per benefit line, artifacts in these classes:

| class | evidence | what it proves |
|---|---|---|
| E1 | Micro-benchmarks with raw output kept on disk | a single operation is X fast on stated hardware |
| E2 | Scaling curves with linear fits + R² | the operation holds up as data grows |
| E3 | Soak/fuzz/court runs (pass counts, seeds, logs) | behavior is robust, not just fast on the happy path |
| E4 | Cross-repo fleet receipts (per-repo JSON) | the result reproduces outside the origin repo |
| E5 | Customer/in-production deployments with wall-clock event timestamps | the benefit occurs for a third party, at real volume, over real time |
| E6 | Interviewed stakeholders + task-level time-and-motion data | humans actually save the modeled time |
| E7 | Financial model tying technical deltas to currency | the claim closes into money a CFO signs |

TEI-style studies combine E1–E4 with E5–E7 and discount by a risk adjustment. Without
E5–E7 you have a performance dossier, not an ROI claim.

## 2. What the fleet already has (on disk today, 2026-10-03)

- **E1, strong**: `bench/hot_paths_raw_w16.json` — 11 hot-path micro-benches with
  stddev, mem/op, harness metadata (aarch64-apple-darwin25.2.0, OTP 28, Elixir 1.19.5,
  16 schedulers). E.g. `standing_receipt_new_validate_to_map` 4.66 µs (σ 3.0%),
  `checkpoint_write_ets_record` 7.83 µs, `ledger_ocel_export_1k` 15.8 ms.
- **E2, strong**: `bench/STORE-SCALING-2026-10-03.md` — Ets vs Dets across n=100/1k/10k
  with reproduction commands, observed cliffs (dets sync ceiling ~145–600 ops/s;
  `checkpoints/2` full-ledger scan 69 µs → 10 ms at 10k). `bench/ocel_export_scaling_raw_w16.txt`
  adds linear fits with R² (record R²=0.9998 LINEAR; export/digest NOT-LINEAR, drift 40–50%)
  out to 100k events with per-pass memory peaks.
- **E3, strong**: `test/standing/*` (cached adversarial, single-flight, chain-unpaired court),
  `test/hardening/*` (19 files: dets crash court, replay fuzz, policy fuzz, status fuzz),
  `test/durable/*` (race/cancel/migration courts). These are real-collaborator court
  tests, not mocks. Soak receipts with two independent runs:
  `bench/fleet/fleet_soak_1791062839.json`, `fleet_soak_1791079797.json` (per-event
  costs at 1k/10k/50k/100k events, two-run agreement visible in the raw files).
- **E4, partial**: `bench/fleet/*.json` — 11 repos with compile/test/bench outcomes.
  Honest caveat: `bench/fleet/ash_pplan.json` itself currently records
  `status: "timeout@20min"`, `bench: skipped` — the fleet surface exists, and it is
  currently honest about a BLOCKED subject. That is an artifact, not a passing one.

## 3. What the fleet lacks (gaps to a diligence-surviving claim)

- **E5**: zero third-party deployments; no wall-clock event timestamps tied to real
  usage (bench event streams are synthetic, generated in-process). No cross-org data.
- **E6**: no time-and-motion baseline of what an engineer does today vs with the
  standing/cache layer; no stakeholder interviews.
- **E7**: no financial model — no loaded hourly cost, no run-frequency telemetry from
  any paying or even internal operator.
- **E4**: fleet receipts are same-machine, same-day; no independent-hardware reproduction.
  The ash_pplan fleet subject is currently BLOCKED (timeout), which must be cleared
  before any E4 claim cites this repo.
- **Temporal validity**: most receipts are same-day (2026-10-03). No longitudinal
  receipts (same bench re-run over weeks) to show the numbers hold.

##  Diligence questions this dossier cannot yet answer

1. Does the 39s → 0.49s delta (below) survive on hardware other than one M-series
   laptop-class machine?
2. What fraction of real workloads hit the cache (hit rate under production access
   patterns)? Bench hits are repeated-identity access — an upper bound.
3. Who runs 10k-event standing computations, how often, and what does their hour cost?

## 4. Worked example — explicitly assumption-labeled, no customer numbers

**Claim shape (only this, and only this much)**: *If* an operator ran a standing
receipt computation over a 10k-event ledger, the on-disk measurements show a large
wall-clock delta between the uncached receipt path and the post-optimization cached
path on this machine.

On-disk facts (both files dated 2026-10-03, same repo, same machine class):

- `bench/receipt_cached_scaling_raw1.json` (14:04Z): at 10,000 events,
  `receipt_us = 39,008,716` ≈ **39.0 s** per uncached standing-receipt computation.
- `bench/receipt_cache_scaling_postfix2.json` (16:03Z): at 10,000 events,
  `receipt_us = 486,601` ≈ **0.49 s**, `cached_hit_us = 18,486` ≈ **18.5 ms**
  (hit speedup vs miss 24.3x, `standing: ALIVE`).

Honest caveats on the delta: the two numbers come from different runs ~2h apart with a
code change between them (raw1 = before, postfix2 = after an optimization wave). The
39s run predates the optimization; the 0.49s run postdates it. Single machine, single
day, no cross-hardware reproduction (gap Q1), and the improvement has not been
attributed run-by-run to specific commits. Treat the delta as *observed on this
machine on 2026-10-03*, not as a guaranteed characterization.

**The ROI arithmetic — every multiplier after the wall-clock delta is an assumption:**

| quantity | value | status |
|---|---|---|
| uncached receipt @ 10k events | 39.0 s | measured (raw1) |
| post-optimization receipt @ 10k events | 0.49 s | measured (postfix2) |
| delta | 38.5 s per full-uncached-equivalent computation | derived from measurements |
| runs per engineer-day needing a fresh receipt | 20 | [ASSUMPTION] |
| working days/year | 250 | [ASSUMPTION] |
| engineers affected | 10 | [ASSUMPTION] |
| fully-loaded engineer cost | $150/h | [ASSUMPTION] |
| wall-clock saved per day | 20 × 38.5 s ≈ 12.8 min | derived from assumption × measurement |
| annual saved time | 12.8 min × 250 d × 10 engineers ≈ 534 h | derived |
| annual value | 534 h × $150 ≈ **$80,100/yr** | assumption-scaled |

Read this as: *the measured delta is real on one machine; the ~$80k/yr figure is an
illustration of scale, contingent on four unmeasured assumptions, and is not evidence
of any actual saving*. If engineers run this once per week rather than 20×/day, the
figure falls ~40x to ~$2,000/yr — the model is a linear function of the run-frequency
assumption, which is exactly the quantity E6 would measure.

A cached-hit framing is even more bounded: hit path 18.5 ms vs 39 s uncached is ~2100x,
but that is the same order as the measured `hit_speedup_vs_miss` band (24x at 10k
against the optimized miss path — the honest comparable is 0.49 s → 18.5 ms, ~26x,
`hit_speedup 26.3` in postfix2).

## 5. What would upgrade this dossier to a claim

1. Clear the ash_pplan fleet receipt BLOCKED (timeout@20min) so E4 cites a passing repo.
2. Re-run the receipt-cache scaling pair on a second hardware class (gap Q1).
3. Instrument run-frequency: log receipt computations with wall-clock timestamps in
   any long-lived deployment (feeds E5/E6).
4. One real operator (internal counts) running ≥1 month: before/after wall-clock and
   hit rates under real access patterns (E5 + E6 partial).
5. Loaded-cost + frequency survey → closes E7. Until then, the $/yr line stays
   labeled illustrative.

## Assumption list

1. 20 fresh standing-receipt computations per engineer-day [ASSUMPTION, unmeasured]
2. 250 working days/year [ASSUMPTION, standard]
3. 10 affected engineers [ASSUMPTION]
4. $150/h fully loaded engineer cost [ASSUMPTION]
5. Bench event streams represent real ledger access patterns (cached-hit rates are
   repeated-identity upper bounds) [ASSUMPTION, likely optimistic]
6. The 39s → 0.49s delta is stable across hardware and over time [ASSUMPTION,
   single-machine single-day measurement]
7. Cached-hit framing (26x vs optimized miss) is the honest comparable; the 2100x vs
   the pre-optimization path is not claimable as steady-state caching benefit [labeling
   choice, conservative]
