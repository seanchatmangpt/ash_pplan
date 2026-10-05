
## P5 25/25 closure attempt — 2026-10-04 08:13-11:36 PDT (falsifier lane)

Procedure: poll for (1) full-suite 0-failure gate, (2) quiescence (two 90s-stable
whole-tree git-status samples AND zero other mix test/sync/check processes), (3)
tmp/.demonstrate-lock absent; then `MIX_BUILD_ROOT=_build-demo-25 mix test
test/demonstration_court_test.exs`.

### Precondition polling (08:13-10:36, ~2.4 h)

- **Lock**: absent at every check (never the blocker this attempt).
- **Full-suite gate**: re-gate lane in flight at start (wrapper PID 17850 ->
  attempt 2 PID 88906, log /tmp/gate-full5.log). Poller waited it out. Result:
  **16 properties, 2298 tests, 7 failures, 76 skipped** (TEST_EXIT=2, wall 3041s).
  All 7 are provenance/vendor-state classes (ReleaseContractTest provenance/
  plan-catalog 2, PackGateWitnessCourtTest vendored-pack sha lock 1,
  PackCourtsHarnessCourtTest anti-vacuity + harness exit-0 2,
  ProvenanceBaselineCourtTest sha256/source_git_sha drift 2) — cross-lane
  vendor-fixture churn, not court defects. **Suite NOT at 0 — precondition (1)
  unmet; the full-test-suite edge cannot be closed this attempt.**
- **Quiescence**: never reached — every one of ~72 polls over ~80 min showed 2-7
  live mix processes from other lanes (/tmp/demo25-pipeline.log). Per procedure
  ("run anyway and record honestly" after 60 min), proceeded at 10:36.

### Run (10:36-11:36 PDT)

```
MIX_BUILD_ROOT=_build-demo-25 mix test test/demonstration_court_test.exs
```

- Log: /tmp/demo25-run.log. **Exit code: 2** (explicit wrapper echo).
- **4 tests, 1 failure**, ExUnit wall 1800.0s. The single failure is the headline
  edge `bin/demonstrate exits 0 and the receipt admits every named edge
  (test/demonstration_court_test.exs:93)` hitting its **1800s ExUnit timeout** —
  PASS_SOLO_TIMEOUT_UNDER_LOAD, the same class as the original classification
  (clean solo run: 445.5s; this run shared the tree with 2-7 concurrent mix
  processes throughout). Not a lock REFUSED, not a compile race, not a court logic
  failure. The other 3 tests pass; compile clean (marketplace_sim glob fix holds).
- Edge count: **not 25/25** — the receipt-generating edge did not complete, so no
  fresh receipt was minted and no edge-level pass count exists for this run.
  Prior best quiescent result remains the P5 entry above (2 tests, 0 failures).

### Verdict

**P5 25/25 edge NOT CLOSED.** Binding constraint = cross-lane load: precondition
(1) failed with 7 provenance/vendor-sha-class failures; precondition (2) never
materialized (zero quiescent windows in ~2.4 h / ~72 samples). Clean closure
still requires the same window as before: zero other lanes on the tree, suite at
0, lock absent — then a fresh-root `mix test test/demonstration_court_test.exs`
should reproduce the P5 quiescent result (0 failures, well under budget).

Logs: /tmp/demo25-pipeline.log (poll log), /tmp/gate-full5.log (re-gate),
/tmp/demo25-run.log (demo run). _build-demo-25 NOT deleted: `rm -rf
_build-demo-25` denied by the permission system (same as _build-gate-full3
before); directory remains on disk for coordinator cleanup. No git operations.
