# Finance Transformation

What ash_pplan's measured performance numbers would mean in a finance-operations
control plane: continuous close, evidence-bound reconciliation, and an audit
trail that is replayable under an admission gate rather than a mutable log.

## Why a finance control plane

A close process is an evidence problem before it is a speed problem. Every
figure in a trial balance traces to transactions; every adjustment traces to a
preparer, a policy, and a moment. A control plane that certifies each step with
a replayable receipt — plan/execution/consequence verdicts, typed refusals —
turns "trust the log" into "replay the evidence." The numbers below describe
whether that certification can run continuously, not just at month-end.

## Receipt-cache: honest speedups, stated with the supersession

The project previously cited ~2100–2200x hit-path speedups for the standing
receipt cache. Those figures were an artifact of a quadratic raw baseline (the
sealed ledger digest was O(n^2)), not a property of the cache. After removing
both quadratics, the honest end-to-end hit speedups are **14.6–29.1x across
cache sizes**, superseding the stale ~2100–2200x figures
(`bench/STANDING-CLOSURE-BASELINE-2026-10-03.md`, "Post-chain-fix refresh";
supersession recorded in `CHANGELOG.md` 26.10.3). Per size, run1/run2:

| evidence size | hit speedup (run1 / run2) | raw receipt | cached hit |
|---|---|---|---|
| 100 events | 14.6x / 15.3x | ~2.6 ms | ~168–183 µs |
| 1,000 events | 17.8x / 17.9x | ~30 ms | ~1.7 ms |
| 10,000 events | 27.0x / 29.1x | ~446–475 ms | ~16.3–16.5 ms |

Finance reading: re-verifying an unchanged 10k-event evidence ledger drops from
~0.46 s to ~16 ms. That is the difference between reconciliation checks that
run per-question and checks that run continuously — every dashboard refresh,
every reviewer query, every downstream consumer re-certifies without paying the
full verification cost. Miss overhead is within run-to-run noise at every size
(−13% to +12%), so the cache never taxes the cold path. Cached and raw
receipts are byte-identical, asserted every run.

## O(n^2) → O(n): the digest repair, 39 s → 0.49 s at 10k events

Before the chain-digest fix, computing a 10k-event standing receipt cost
32.7–39.0 s — the sealed ledger digest was quadratic in evidence size. After
the O(n^2)→O(n) repair (commit `db178fa`), the same call costs 486,601 µs ≈
**0.49 s** — roughly **80x**, and the cost now scales linearly
(`bench/STANDING-CLOSURE-BASELINE-2026-10-03.md`, receipt-cache scaling table;
raw receipt per size: ~2.6 ms @ 100 → ~30 ms @ 1k → ~446–475 ms @ 10k).

The companion chain-build path (`build_sealed/4`) at 10k events went from
~1,005 s (order-of-magnitude, measured under concurrent load) to 126–211 ms —
a ~5,000–8,000x removal of a pure quadratic. A further `plan_correct` hoist
cut a 4k-event receipt from 7.45–7.97 s to 172–180 ms (~45x), confirming a
second quadratic.

Finance reading: this is the difference between "evidence verification is a
batch job" and "evidence verification is an online operation." At 39 s per
10k-event ledger, continuous close is arithmetically impossible; at 0.49 s
with linear scaling, per-ledger verification fits inside a reconciliation
loop. Receipt scaling stays ~linear at a much lower constant: 3.2 µs/event at
1k vs ~420 µs/event before the fix (−92% at 1k events,
`bench/BASELINES-CANONICAL.md` §Post-chain-fix refresh).

## Wedge repair: 70 wedges/run → 0

DETS reads used to take a full-table `:dets.sync` per operation. Under
kill-storm load this wedged the store at a rate of **~70 wedges per run**; the
fix (sync-on-write-only, a 60 s bounded-call timeout that converts a wedged
server into a typed refusal, and signal lookups pushed into DETS match specs)
produces **0 wedges across 4 soak runs**
(`CHANGELOG.md` 26.10.3, "DETS wedge fix"; regression court
`test/hardening/dets_read_no_sync_test.exs`, 11 tests). A repair-aware reopen
retry (bounded backoff, <=750 ms) now absorbs kill-mid-sync reopen failures.

Finance reading: a wedge in a finance control plane is a frozen sub-ledger
during close. 70 → 0 wedges per kill-storm run is the difference between an
operations team that babysits storage during peak load and one that does not.

## Large-ledger evidence: 0.49 s receipts, 2.4 s exports at 100k

The largest directly measured receipt is the 10k-event one at ~0.49 s (above).
At the 100k-event scale, the OCEL evidence ledger is measured directly:
export of a 100k-event run takes **~2.4 s**, recording is LINEAR
(R^2 = 0.9995), and a reductions probe shows work per event FLAT to within
+2.4% across 1k→100k events — no algorithmic superlinearity anywhere in the
composite (`bench/BASELINES-CANONICAL.md` §6 and §P4 follow-up).
A 100k-event *receipt* is not directly measured; see Limitations.

Finance reading: a 100k-event ledger is roughly a mid-size entity's quarterly
transaction-evidence volume per process. Sub-3-second export and flat per-event
work mean the evidence tier is not the bottleneck of a continuous close; the
close cadence is bounded by policy decisions, not ledger mechanics.

## Store-scaling bands: plan the storage tier from bands, not points

DETS absolute latencies vary up to ~4–6x run to run (disk-page variance); the
canonical baseline records them as bands and says explicitly: use the bands,
not points (`bench/BASELINES-CANONICAL.md` §2):

| metric | ETS | DETS |
|---|---|---|
| write ops/s | 299–490k (n>=1k) | 75–599 (ceiling ~600) |
| get_run µs | 1.0 flat | 25–469 |
| checkpoints() µs at 10k | 10,066–16,663 | 37,078–245,365 |
| sig dispatch ops/s | ~84–210k | ~30–300 |

Finance reading: ETS is the continuous-close tier (flat 1 µs lookups,
hundreds of thousands of writes/s); DETS is the durable archive tier with a
write ceiling of a few hundred ops/s and order-of-magnitude dispatch spread.
A finance deployment sizes its hot/cold split from these bands — journal-entry
ingestion on ETS with checkpointing, archive replay through DETS with the
known ceilings — rather than from point measurements that noise would
contradict.

## Limitations

These are single-machine synthetic benchmarks (aarch64 Darwin, OTP 28, 16
schedulers), many taken under concurrent fleet load, with recorded run-to-run
variance; DETS rows are bands, and the ladder/policy rows are the weakest
numbers in the consolidation. They are engineering measurements of this code
on this box — **not customer outcomes**. No finance deployment, dataset, or
close cycle was measured; the finance readings above are structural
implications of the numbers, not results observed in a production finance
environment. The 100k-event *receipt* is extrapolated context, not a direct
measurement (only OCEL export at 100k is directly measured). Absolute numbers
will differ on other hardware; the scaling shapes (linear receipts, flat
per-event work, banded DETS) are the transferable claims.

## See Also

`docs/case-studies/comparison.md` · `bench/BASELINES-CANONICAL.md` ·
`bench/STANDING-CLOSURE-BASELINE-2026-10-03.md`
