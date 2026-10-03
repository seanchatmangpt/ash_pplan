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
