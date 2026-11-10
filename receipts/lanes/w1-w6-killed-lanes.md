# W1–W6 — killed lanes (combined receipt)

Standing: BLOCKED

Evidence class: SR (session record), materialized 2026-11-07 under the
coordinator addendum: the session record carries executed-gate verdicts for
every landed lane; each verdict below was reported by its lane with real
command exits in-session. Stale-by-default per law (SR-VALID).

Verdict: all six lanes killed mid-flight; partial edits inventoried in the
WIP snapshot commit ea21645 ("chore(wip): snapshot of killed-lane WIP state
(W1-W6, A3, A4, T2 partial edits)"), not resumed as truth (subagent lane
law). Successor work ran as the Z-wave; W2 additionally closed dead lanes
Z1 and Z6 on disk (companion receipts: `z1-take_signal.md`,
`z6-wal-bench.md`).

## Lanes

| lane | verdict | disposition |
|---|---|---|
| W1 | BLOCKED | killed mid-flight; edits in ea21645 |
| W2 | BLOCKED | killed mid-flight; also closed Z1 + Z6 (disk) |
| W3 | BLOCKED | killed mid-flight; Z11/Z18 pass-through via W3 |
| W4 | BLOCKED | killed mid-flight; edits in ea21645 |
| W5 | BLOCKED | killed mid-flight; edits in ea21645 |
| W6 | BLOCKED | killed mid-flight; edits in ea21645 |
