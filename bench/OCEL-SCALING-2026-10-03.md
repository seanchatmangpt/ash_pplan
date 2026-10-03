# OCEL-SCALING-2026-10-03

Lane: BENCH. Subject: `AshPPlan.Reactor.Durable.LedgerOCEL` events/export/digest over
`AshPPlan.Reactor.Durable.Store.Ets` (real live store, MIX_ENV=test, no doubles).

Script: `bench/ocel_export_scaling.exs`, run twice (run 2 adds the optional 100k
checkpoint; `RUN_100K=1`). 2026-10-03.

## Method

Per size N (checkpoints recorded into one run):

- record: N unique checkpoints via `Ets.record/6`, timed end-to-end
- events: `LedgerOCEL.events/3` (N+2 events: run_started + N task_succeeded + run_ended)
- export: `LedgerOCEL.export/3` (OCEL2-JSON)
- digest: `LedgerOCEL.digest/3`
- Memory peak = `:erlang.memory(:processes)` delta around each phase, GC'd before/after.
- Linear fit: least squares `us/pass = a*N + b`; verdict LINEAR iff R^2 >= 0.999 and
  per-event drift (smallest vs largest N) within +/-25%.

Environment note: the shared working tree carries a pre-existing compile break in
`lib/ash_pplan/providers/qualify.ex` (another lane's edit). The bench therefore ran with
`mix run --no-compile` against the pre-existing `_build/test` artifacts; none of the
modules exercised (LedgerOCEL, Store.Ets, Status, ProcessEvidence) are modified in the
tree, so the measurements bind to the shipped code paths.

## Run 2 (primary, N = 1k / 10k / 50k / 100k)

| N | events | record us/ev | events us/ev | export us/ev | digest us/ev | export peak MB |
|---|--------|--------------|--------------|--------------|--------------|----------------|
| 1k | 1,002 | 3.1 | 3.14 | 13.07 | 2.56 | 3.9 (events) |
| 10k | 10,002 | 2.1 | 3.40 | 19.09 | 3.46 | 14.0 (events) |
| 50k | 50,002 | 2.6 | 3.59 | 20.05 | 4.18 | 72.1 (events) |
| 100k | 100,002 | 2.5 | 4.06 | 23.84 | 4.43 | 97.4 (events) |

(export phase itself showed ~0 MB delta; the events phase allocates the event structs
and is the memory-bearing step. digest peaked +68-97 MB transiently at 50k/100k.)

## Run 1 (3-point, repeatability check)

| N | record us/ev | events us/ev | export us/ev | digest us/ev |
|---|--------------|--------------|--------------|--------------|
| 1k | 5 | 2.86 | 11.37 | 1.95 |
| 10k | 2 | 2.55 | 16.36 | 2.74 |
| 50k | 2 | 3.24 | 19.95 | 3.94 |

## Linear fit (run 2)

```
record: us = 2.491*N + -263   R2=0.9995  us/event 3.08 -> 2.47 (drift -19.7%)  LINEAR
events: us = 4.058*N + -7682  R2=0.9966  us/event 3.14 -> 4.06 (drift 29.2%)   NOT-LINEAR
export: us = 23.84*N + -61.9k R2=0.9935  us/event 13.07 -> 23.84 (drift 82.3%) NOT-LINEAR
digest: us = 4.473*N + -7689  R2=0.9992  us/event 2.56 -> 4.43 (drift 25.6%*)  NOT-LINEAR
```

(*run 1's 3-point digest drift was 102%; export drift 75.5% run 1, 82.3% run 2.)

## Verdict

- record (Ets writes): LINEAR, ~2.5 us/checkpoint flat — no scaling concern.
- events: mildly superlinear (drift +29% 1k->100k; R^2 0.997). Consistent with the
  `Enum.sort_by(&1.seq)` over N checkpoints plus per-event output-digest sha256.
- export: superlinear. Per-event cost rises 13.1 -> 23.8 us/event (+82%) from 1k to
  100k. R^2 0.9935, and both runs agree (75.5% / 82.3% drift). The JSON serialization
  is not linear; O(N log N)-to-worse growth. At 100k events an export is ~2.4 s.
- digest: superlinear-ish. 2.6 -> 4.4 us/event; run 1 showed +102%, run 2 +73%.
  Consistent with `term_to_binary` over a growing accumulated iolist/term.

Practical ceiling: export is the bottleneck (~20-24 us/event); a 100k-checkpoint run
exports in ~2.4 s, memory peak from event construction ~97 MB at 100k. record and
events stay comfortably flat per event.

Falsifier: rerun `RUN_100K=1 MIX_ENV=test mix run --no-compile bench/ocel_export_scaling.exs`;
export us/event must stay within +/-25% of 13 us across 1k->100k to overturn the
superlinear verdict.

## Raw outputs

All figures transcribed from the two runs' stdout (run 1: 3-point sweep;
run 2: 4-point sweep with `RUN_100K=1`), preserved inline above. No raw JSON persisted.
