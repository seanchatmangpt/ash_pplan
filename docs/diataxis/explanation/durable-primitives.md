# durable-primitives

The durable execution subsystem rests on four primitives. This page states
what each one provably does today (V5 probe, 2026-11-07, `/tmp/v5_out.txt`),
not what it aspires to do.

## WAL (`AshPPlan.Reactor.Durable.Store.Wal`)

Segmented append-only log, frames `<<len::32, crc32::32, payload>>`.

Proven:

- Reopen fidelity: 200 checkpoints plus run status, pending signal, waiter
  wake, and undone metadata survive close/reopen (V5 P10).
- Reopen after corruption does not crash the reader.

Open (mid-repair, lane A5):

- Integrity policy is resync-or-refuse (see `parse_frames/1`): corrupt frames
  are skipped and a torn tail is truncated. V5 P1 showed a mid-frame byte
  flip dropped with no typed integrity error; P3 showed a torn 5-byte prefix
  loses the run before it. Refusal semantics are pending A5's repair.
- Concurrent `claim/5` can double-grant (V5 P4).
- Expired-lease steal and claim-on-missing-run return `:taken` (V5 P5).

## RingBuffer (`AshPPlan.Reactor.Durable.RingBuffer`)

A monotonic sequence allocator over a public ETS table with atomic
`:ets.update_counter/3` head allocation. Bounding semantics per LANE-A5.

Proven:

- Atomic multi-writer head allocation: 8 writers x 2000 pushes preserved
  every sequence (V5 P7).
- `prune/1` deletes below the ack watermark.

Open:

- Not capacity-bounded: 20,000 pushes produced 20,003 rows, no wrap (V5 P6).
- `prune/1` with ack = head empties the readable window (V5 P6). Do not call
  it a "pre-allocated bounded ring" until a bounded implementation lands.

## HealthGate

Three-phase JPL-style pre-actuation gate: `pre_check/2` -> `actuate` ->
`post_telemetry/3`.

Proven:

- Fails closed: pre-check refusal runs before actuation; `run_fun/2` is
  never invoked on refusal (V5 P8).
- Refusal shape `{:error, {:refused, {:health_gate_violation, reason}}}`.

Open (lane A5):

- The `@spec` says `{:refused, term()}`; the implementation returns refusals
  under `{:error, _}`. Spec/return contract mismatch, pending A5.
- Non-`:ok`/non-`{:error, _}` pre-check returns pass through unrefused with
  no telemetry (V5 P8).

## LeaseMonitor

GenServer-held `{owner_pid, epoch, ref}` leases with `Process.monitor/1`.

Proven (V5 P9):

- Holder kill releases the lease in ~16ms (monitor trip, no polling).
- 50 concurrent claims yield exactly 1 winner.
- Heartbeat by a non-holder: `{:error, :not_held}`; release by non-holder is
  a no-op `:ok`.

Open:

- None observed in V5 P9.

## What each claim is traceable to

Every claim on this page cites a V5 probe paragraph (P1-P10,
`/tmp/v5_out.txt`) or is explicitly marked `[LANE-A5-BOUNDARY]` where lane
A5 is mid-repair. Aspirational figures ("sub-10 microsecond", "pre-allocated
ring", "bit-for-bit determinism") are not asserted anywhere in these docs
without a benchmark or V5 citation.

See Also: `docs/diataxis/explanation/durable-ledger-and-stores.md`
