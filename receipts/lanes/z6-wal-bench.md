# Z6 WAL bench closure (lane W2)

Standing: ALIVE

Lane: W2 (closing lane), closing dead lane Z6.

## Scope

`bench/CLAIMS-BASELINE-2026-11-07.md` WAL row + `lib/ash_pplan/reactor/durable/store/wal.ex`
batched-append writer verification.

## Verification runs (all this session, MIX_BUILD_ROOT=_build-w2)

- Z6's batched writer in `store/wal.ex` compiles and passes:
  - `mix test test/durable/store_wal_integrity_test.exs` — green (part of 114/0 combined run)
  - `mix test test/durable/store_conformance_wal_test.exs` — green (same run)
  - Combined gate run: `mix test test/durable/store_take_signal_test.exs
    test/durable/store_wal_integrity_test.exs test/durable/store_conformance_wal_test.exs
    test/durable/phase_kill_test.exs test/durable/await_test.exs
    test/durable/store_conformance_dets_test.exs
    test/durable/store_conformance_ets_test.exs` → **114 tests, 0 failures**.
- Full `mix test test/durable/` → 10 properties, 437 tests, 28 failures, 1 skipped.
  The failures are pre-existing reds outside W2 scope (ledger digest tamper-evidence,
  trace-model courts, ExecutionReceipt, engine lease/harness courts); ledger failures
  reproduce in isolation with zero take_signal involvement.

## Baseline doc

`bench/CLAIMS-BASELINE-2026-11-07.md` Z6 table now carries the measured range:
`29,107 (load-dependent: 29k–88k across Z6's runs)` for WAL append frames/s.
F1 historical rows (705 frames/s baseline) left intact as the before figure.

## Z6 change verified in place

Batched-append writer (one persistent `:raw` device + mailbox-drain coalescing, caller-acked
durability preserved, kill-mid-burst court intact): 29k–88k frames/s load-dependent vs the
705 frames/s per-frame `File.write!` baseline — target >2000 EXCEEDED.
