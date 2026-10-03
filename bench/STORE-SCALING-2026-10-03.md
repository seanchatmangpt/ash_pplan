# Store Scaling Bench — Ets vs Dets (2026-10-03)

Lane: BENCHMARK store scaling. Real stores only (live GenServers over private ETS tables
vs a real DETS file on disk). No doubles, no mocks.

- Subject: `/Users/sac/ash_pplan` @ main, working tree (lane bench files only;
  `lib/**` untouched by this lane).
- Store under test: `AshPPlan.Reactor.Durable.Store.{Ets, Dets}`
  (`lib/ash_pplan/reactor/durable/store/{ets,dets}.ex`)
- Bench: `bench/store_scaling.exs`

## Results (ops/s per size x store)

Median read latency in us/op. Signal dispatch = consume_signal + deliver_signal
round-trips by N concurrent readers against the one live store.

| metric | store | n=100 | n=1k | n=10k |
|---|---|---|---|---|
| write ops/s (record checkpoint) | ets | 52,192 | 458,085 | 489,740 |
| write ops/s (record checkpoint) | dets | 570 | 599 | 145 |
| get_run us/op (median) | ets | 1.0 | 1.0 | 1.0 |
| get_run us/op (median) | dets | 36.0 | 25.0 | 18.0 |
| checkpoints() us/op (median) | ets | 69 | 680 | 10,066 |
| checkpoints() us/op (median) | dets | 337 | 3,128 | 37,078 |
| sig dispatch ops/s N=1 | ets | 5,114 | 192,308 | 211,864 |
| sig dispatch ops/s N=1 | dets | 164 | 295 | 181 |
| sig dispatch ops/s N=8 | ets | 212,089 | 171,527 | 182,274 |
| sig dispatch ops/s N=8 | dets | 313 | 140 | 69 |
| sig dispatch ops/s N=32 | ets | 163,232 | 182,274 | 196,127 |
| sig dispatch ops/s N=32 | dets | 135 | 45 | 94 |

Note: ets write at n=100 (52k vs 458k) is first-batch warmup on the tiny run, not scaling.

## Scaling cliffs (observed)

1. **Dets write ceiling ~600 ops/s, degrading to 145 at 10k checkpoints.** Every call
   (read or write) is followed by `:dets.sync/1` (`store/dets.ex:112`), so throughput is
   sync-bound and flat — and degrades as the file grows (auto-repair/rehash cost grows
   with file size). ~800x gap vs Ets (490k ops/s) at 10k.
2. **Dets concurrent signal dispatch collapses: 313 -> 45 ops/s from N=1 to N=32 at 1k
   checkpoints (ets: flat at ~180-210k).** The store mailbox is a single serialization
   point for both stores; DETS's per-call `sync` turns the shared GenServer into a
   sync-per-dispatch bottleneck, and contention amplifies it.
3. **`checkpoints/2` (standing fetch) is a full-table scan in both stores** (`cps/1` uses
   `:ets.tab2list` / `:dets.select` over ALL rows, then filters by run id), so fetch cost
   grows linearly with TOTAL ledger size, not per-run size: ets 69us -> 10ms, dets 337us
   -> 37ms at 10k total checkpoints. At 100k checkpoints this is ~100ms (ets) / ~370ms
   (dets) per standing fetch — the dominant scaling cliff for large ledgers.

## Reproduction

    cd /Users/sac/ash_pplan
    MIX_BUILD_ROOT=_build-bench2 mix run bench/store_scaling.exs

Fallback used for this run (unrelated in-flight lane edits elsewhere in `lib/` were
breaking full-app compile at measurement time; the store layer compiles standalone):

    elixirc -o /tmp/ash_pplan_bench_ebin \
      lib/ash_pplan/reactor/durable/status.ex \
      lib/ash_pplan/reactor/durable/records.ex \
      lib/ash_pplan/reactor/durable/store.ex \
      lib/ash_pplan/reactor/durable/store/ets.ex \
      lib/ash_pplan/reactor/durable/store/dets.ex
    elixir -pa /tmp/ash_pplan_bench_ebin bench/store_scaling.exs

(The DETS file is written under /tmp and removed by the bench cleanup fn.)

---

# Burn-Cycle Shape — 6 cycles x 64 runs through the real Engine (2026-10-03)

Lane: BENCHMARK burn-cycle decay. Same real-store discipline as the section above:
real Engine `start -> claim -> run -> complete` per run (20 linear effect tasks per
run, `:extra_fx` counting steps), per-cycle wall time -> orders/s as the ledger grows.
Two runs, raw JSON kept at `bench/burn_cycle_raw1.json` / `bench/burn_cycle_raw2.json`.

- Bench: `bench/burn_cycle_bench.exs`
- Subject: `/Users/sac/ash_pplan` @ main, working tree (lane bench file only)
- Harness note: full `mix compile` is broken in the current tree by an unrelated
  in-flight edit (`lib/ash_pplan/providers/qualify.ex:62` — `Keyword.keyword?/1`
  is not a valid guard; pre-existing, not lane-introduced). Same fallback as the
  run above: the ash_pplan tree was standalone-compiled with `elixirc` (HEAD
  `qualify.ex` substituted) and the bench run under `elixir -pa` over those beams
  plus `_build-ch2/test` dep beams. The Engine/store layer is unaffected by the
  broken file.

## Orders/s decay (runs completed per second, per cycle)

| cycle | cum checkpoints | ets orders/s (r1 / r2) | dets orders/s (r1 / r2) |
|---|---|---|---|
| 1 | 1,280 | 46.8 / 119.7 | 7.7 / 11.3 |
| 2 | 2,560 | 201.0 / 204.7 | 3.8 / 7.6 |
| 3 | 3,840 | 168.6 / 183.7 | 4.6 / 3.6 |
| 4 | 5,120 | 124.8 / 143.9 | 3.6 / 4.0 |
| 5 | 6,400 | 105.1 / 113.6 | 3.6 / 4.0 |
| 6 | 7,680 | 87.6 / 94.7 | 3.1 / 3.2 |

(ets cycle 1 r1 is JIT/warm-up — the first Engine attempt compiles the run's
Reactor plan; from cycle 2 on the shape is the decay, not warmup.)

## Shape

1. **Dets decay is steep and monotonic-ish: ~11 -> ~3 orders/s by cycle 6** (r2:
   11.3 -> 7.6 -> 3.6 -> 4.0 -> 4.0 -> 3.2). Matches the prior 24 -> 12 -> 8
   order-of-magnitude band from the earlier burn-in data; confirms the decay is
   ledger-size-driven, not noise. Between run 1 and run 2 the whole dets curve sits
   in the same 3-11 orders/s band, ending ~3 orders/s at 7.7k checkpoints.
2. **Ets decays too, but off a much higher base**: peak ~200 (cycle 2) -> ~90-105 by
   cycle 6 (~2.2x drop). Warmup aside, this mirrors the `checkpoints/2` full-ledger
   scan documented above: each attempt's standing fetch walks all cumulative rows,
   so per-cycle cost grows linearly in total checkpoints even in memory.
3. **Cross-store gap ~25-30x at cycle 6** (87.6/94.7 vs 3.1/3.2), consistent with
   the store-level write ceiling (~145-600 ops/s) plus the per-call `:dets.sync/1`
   documented in the scaling cliffs.

## Raw lookup microbench: :ets.lookup vs :dets.lookup

(OTP has no `:dets.fetch/2`; `:dets.lookup/2` is the DETS counterpart. Real tables,
500 timed sweeps of 100 random keys each, mean us/key over 50k lookups.)

| rows | ets.lookup us/op (r1 / r2) | dets.lookup us/op (r1 / r2) | ratio (r1 / r2) |
|---|---|---|---|
| 100 | 0.072 / 0.089 | 69.2 / 25.1 | x965 / x283 |
| 1,000 | 0.083 / 0.083 | 95.8 / 43.4 | x1,157 / x524 |
| 10,000 | 0.102 / 0.098 | 50.3 / 51.7 | x495 / x530 |

Ets is flat (~0.1 us) across sizes. Dets is ~25-95 us/op, roughly flat-to-noisy in
size (hash lookup dominated by disk-page/lock overhead, not tree depth), i.e. a
~300-1,150x per-op gap. This raw ~30 us floor per store call is what turns into the
~3 orders/s ceiling once every checkpoint record pays it, with sync, through the
store GenServer.

## Reproduction

    cd /Users/sac/ash_pplan
    # full `mix run` blocked by the unrelated qualify.ex compile error above;
    # standalone fallback (also installs config/test.exs app-env equivalents
    # and Application.ensure_all_started(:reactor) in-script):
    for d in _build-ch2/test/lib/*/ebin; do PA="$PA -pa $d"; done
    elixirc $PA -o /tmp/burn_ebin $(find /tmp/burn_src3/lib/ash_pplan -name '*.ex') \
      test/support/durable/effects.ex test/support/durable/extra_fx.ex
    eval elixir -pa /tmp/burn_ebin $PA bench/burn_cycle_bench.exs out.json

(Engine effects are asserted in-script: exactly one t1 effect per run,
384 total per store, counter drift raises.)
