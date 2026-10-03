# DETS Repair-Wait Re-Verify — 2026-10-03

Closes the "owning lane should re-verify" note in
`bench/STANDING-CLOSURE-BASELINE-2026-10-03.md`.

- Subject: `/Users/sac/ash_pplan` @ `main` (working tree, post-freeze `5d80623`)
- Build root: `MIX_BUILD_ROOT=_build-p89`
- Command:

```
MIX_BUILD_ROOT=_build-p89 mix test \
  test/hardening/dets_crash_court_test.exs \
  test/hardening/dets_reopen_retry_test.exs \
  test/hardening/dets_read_no_sync_test.exs \
  test/stress/dets_burn_in_test.exs --include stress
```

(Original dispatch listed `dets_read_no_sync_test.exs` twice; the duplicate
path was de-duplicated — the file ran once in this suite.)

## Result

```
Finished in 60.3 seconds (60.3s async, 0.00s sync)
12 tests, 0 failures
```

Expected noise: `kill mid-burst` crash-court tests intentionally SIGKILL the
DETS writer GenServer, so supervised Task terminate logs
(`GenServer.call ... ** (EXIT) killed`) appear for the burst tasks. These are
the court's observed kill semantics, not failures — the post-kill assertions
(every acknowledged write intact, lock free, seq continues) passed.

## Per-file verdicts

| File | Tests | Verdict |
|---|---|---|
| test/hardening/dets_crash_court_test.exs | pass | PASS (kill-mid-burst durability holds) |
| test/hardening/dets_reopen_retry_test.exs | pass | PASS |
| test/hardening/dets_read_no_sync_test.exs | pass | PASS (read-no-sync repair-wait path) |
| test/stress/dets_burn_in_test.exs (`--include stress`) | pass | PASS |

Standing: ALIVE on exact working-tree subject — DETS repair-wait behavior
re-verified green after the freeze (`dd9024d` fix wave + `5d80623`).
