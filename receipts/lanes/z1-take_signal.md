# Z1 take_signal closure (lane W2)

Standing: ALIVE

Lane: W2 (closing lane), closing dead lane Z1.

## Dispatch vs court conflict (flagged per dispatch-is-executable)

The dispatch stated the correct law as "adopt only in response to a pending signal".
Z1's own court (`test/durable/store_take_signal_test.exs`) initially pinned the OPPOSITE for
same-key re-takes (returns standing cp). Resolved on falsifying evidence, not dispatch text:
same-key adopt-regardless breaks Await consume-once (test/durable/await_test.exs "early signal
is taken" fails under adopt law — real-collaborator evidence) and engine recovery replays from
the standing checkpoint set (engine.ex "Driven from the checkpoints, not replayed"), not from
take_signal. Final law: STRICT — take_signal with no pending signal answers `:none` for every
step key; the ADOPT-consume transition (consume + waiter release + cp return) fires only against
a pending signal (replay adopt). Landing matches the dispatch law; the court's same-key
assertions were Z1 residue, updated to pin the strict law.

## Landing (all three stores)

- `lib/ash_pplan/reactor/durable/store/ets.ex`, `store/dets.ex`, `store/wal.ex`:
  take_signal sig-first — no pending signal → `:none` for every step key; pending + standing cp
  → replay adopt (consume, waiter release, cp unchanged); pending + no cp → fresh take
  (checkpoint frame(s) + consume + waiter release, atomic per-store law).
- `lib/ash_pplan/reactor/durable/store.ex`: callback doc states the strict law.
- `test/durable/store_take_signal_test.exs`: court updated to strict law (re-take → :none;
  kill_between asserts payload durable in the standing set + re-take :none).
- Conformance ontology (`test/support/durable/store_conformance.ex`): `{:take_signal, 7}` added
  to @callbacks (was missing — Z1 residue, failed the callbacks-equal-behaviour anti-vacuity
  test), `take_signal_atomic` law declared + implemented + dispatch clause added.
- Mutant `TakeSignalAdoptRegardless` (conformance dets) kills the new law — anti-vacuity green.

## Verification runs (this session)

- Gate run: take_signal court + WAL integrity + WAL conformance + phase_kill + await +
  conformance dets/ets → **114 tests, 0 failures**.
- Atomicity probe (dispatch law, per store incl. WAL): deliver → take_signal → cp.output ==
  payload, signal consumed (pending_signal nil), waiter gone, second take `:none` — pinned by
  `take_signal_atomic` law in the conformance harness, run per store Ets/Dets/Wal.
- Full `mix test test/durable/` → 437 tests, 28 failures — all pre-existing reds outside W2
  scope (ledger digest tamper-evidence reproduces in isolation with no take_signal
  involvement; trace-model / receipt / engine-lease courts likewise store-independent).

## Z1 residue fixed beyond store code

- Ontology @callbacks missing take_signal (anti-vacuity red) — added.
- Court same-key adopt assertions contradicting strict law — updated.
- take_signal_atomic law + adopt-regardless mutant — added.
