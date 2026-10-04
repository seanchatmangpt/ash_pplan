# Bench Triage Receipt — 2026-10-04

Subject: working-tree modifications under `bench/` in /Users/sac/ash_pplan (branch main, HEAD 9a89aac).
Method: `git diff --stat` + log-tail spot checks + JSON/log cross-check. Read-only; no bench file touched.

## Diff scope

10 files, +18,945 / −4,850. Largest: `bench/fleet/logs/beam4pm.test.log` (+22k lines, full fleet-wave rerun).

## Verdict table

| File | Diff shape | Tail / summary line | JSON cross-check | Verdict |
|---|---|---|---|---|
| bench/fleet/beam4pm.json | 1 line: failures 3→48 | — | matches log tail exactly (1693 tests, 48 failures, 147 skipped) | keep |
| bench/fleet/xaas.json | counts zeroed, status=`timeout@20min` | log has NO `N tests` summary line (run killed mid-run) | consistent: timeout explains zeroed counts | keep |
| bench/fleet/logs/ash_ex4pm.test.log | +406 | `Finished in 9.1 seconds … 131 tests, 0 failures, 4 skipped` | — | keep (fresh artifact) |
| bench/fleet/logs/ash_graphlaw.test.log | ±118 | NO summary line; ends in `{noproc, GenServer call ExUnit.CaptureServer …}` crash during on_exit | — | keep (fresh artifact, run crashed after tests) |
| bench/fleet/logs/beam4pm.test.log | +22,004 | `Finished in 388.4 seconds … 6 doctests, 1693 tests, 48 failures, 147 skipped` | matches beam4pm.json (48) | keep |
| bench/fleet/logs/ex4pm.test.log | ±74 | `Finished in 66.3 seconds … 887 tests, 0 failures, 6 skipped` | — | keep (fresh artifact) |
| bench/fleet/logs/xaas.test.log | ±627 | NO summary line; ends mid-failure (`v26_9_23_goal_test.exs:820`) then os_mon shutdown | consistent with json `timeout@20min` | keep |
| bench/fleet/logs/ash_graphlaw.compile.log | −152 (now empty) | empty file | clean/no-op compile → empty log is normal churn | keep |
| bench/fleet/logs/ex4pm.compile.log | −2 (now empty) | empty file | same | keep |
| bench/ocel_w24_raw.txt | +402 | ends with w24 linear-fit lines (`NOT-LINEAR` drift rows) | expected w24 export tee (cf. commit 65b6d46 "bench: w23/w24 ocel export raw tees") | keep |

## Cross-check results

- beam4pm: json failures=48 == log tail `48 failures`. MATCH.
- xaas: json `timeout@20min` + zeroed counts == log lacking any summary line. CONSISTENT.
- No file shows hand-edit signatures (no truncation mid-diff, no prose/formatting deltas, all mtimes cluster 2026-10-03 21:09–21:37 — one fleet wave).

## Findings (not triage verdicts)

- Regression signal: beam4pm failures rose 3 → 48 in the fresh wave. Artifact is valid; the underlying repo regressed (bench json `bench.exit: skipped, why: tests failed`).
- ash_graphlaw test run ends in an ExUnit CaptureServer noproc crash after tests (summary line never flushed).

## Standing

All 10 modified bench files: KEEP (fresh 2026-10-03 fleet-wave artifacts, json/log mutually consistent). No needs-regen, no revert.
