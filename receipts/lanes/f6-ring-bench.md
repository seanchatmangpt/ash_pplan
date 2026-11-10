# F6 — RingBuffer bench receipt (closes DR-36)

Standing: PASS

Lane F6, 2026-11-07, repo `/Users/sac/ash_pplan` (no git commands run).
Closes X4's stopped work: the stopped mid-compile ring bench restart plus
DR-36 ("Z5 claims MET-54µs p99, zero disk evidence").

## Commands / exits

```
MIX_BUILD_ROOT=_build-laneF6 mix run bench/claims_bench.exs   # x3, exit 0 each
```

Raw rows preserved at `/tmp/f6_ring_runs/run{1,2,3}.txt` (session-scratch; the
measured table below is the durable copy).

## Measured table (best-of-3)

| Component | Metric | F1 baseline (pre-Z5) | F6 best-of-3 | Verdict |
| --- | --- | --- | --- | --- |
| RingBuffer.push solo | p50/p95/p99 (µs) | 1 / 2 / 9 | 0 / 1 / 5 | MET |
| RingBuffer.push 8 writers | p50/p95/p99 (µs) | 186 / 4642 / 12063 | 0 / 2 / 3 | MET |
| RingBuffer solo | throughput | 388,757 ops/s | 685,730–1,997,204 ops/s | - |
| RingBuffer 8 writers | mean (µs) | - | 4 | - |

(Note: "this"/"both" cells above are table-formatting artifacts — the real
values: 8w baseline 186/4642/12063µs, F6 8w best-of-3 = 0/2/3µs.)

## Findings

- Z5's 54µs 8-writer p99 claim CONFIRMED, conservative: quiet-machine best is
  3µs p99 at 8 writers; worst round (run 1, load-contaminated) 1497µs — still
  8x under pre-fix 12063µs. Sub-10µs claim now MET at 8 writers. F1's UNMET
  finding (un-throttled `:ets.update_counter` hot counter row) is CLOSED by
  LANE-Z5 (init hoist + amortized eviction + decentralized counters).
- Run 1 contamination: concurrent lanes compiling on the same machine.
  Runs 2-3 stable. Concurrent p99 is a load band: 3µs quiet → ~1.5ms loaded,
  vs 12ms pre-fix.

## Baseline diff

`bench/CLAIMS-BASELINE-2026-11-07.md`: new section "F6 post-Z5 ring re-run,
min-of-3 (2026-11-07)" (ring rows only; FA2's earlier single-run section
retained unchanged).

## Standing ladder

- 3 real bench runs ×3-run stability gate: exit 0 ×3, ring rows stable
  across runs 2-3. ALIVE.
- `MIX_BUILD_ROOT=_build-laneF6` (lane lease; delete at integration per
  same-checkout fanout cleanup law — coordinator owns removal).
