# Z1–Z6 — Z-wave group receipt

Standing: PARTIAL

Evidence class: SR (session record), materialized 2026-11-07 under the
coordinator addendum (SR-VALID, stale-by-default per law).

Per-lane verdicts:

| lane | standing | note |
|---|---|---|
| Z1 | PASS (landed) | stopped-then-landed; full disk receipt:
`z1-take_signal.md` (lane W2 closure, Standing ALIVE) — take_signal strict
law, adopt-only-on-pending-signal, all three stores |
| Z2 | PASS (landed) | stopped-then-landed (SR) |
| Z3 | PASS | SR |
| Z4 | PARTIAL_ALIVE | SR |
| Z5 | PASS | SR |
| Z6 | PASS (landed) | stopped-then-landed via W2; disk receipt:
`z6-wal-bench.md` (Standing ALIVE) |

Group standing PARTIAL because Z4 is PARTIAL_ALIVE; the five landed/PASS
lanes are individually cited above.
