# Gate Receipt: durable suite — 2026-10-04

## Subject
- Repo: /Users/sac/ash_pplan (canonical checkout, branch main)
- Build root: `_build-gate-dur` (lane-isolated, deleted after run)
- No source/test files modified.

## Commands + exits
| command | exit |
|---|---|
| `MIX_BUILD_ROOT=_build-gate-dur mix compile --warnings-as-errors` | 0 |
| `MIX_BUILD_ROOT=_build-gate-dur mix test test/durable/` | 0 |

No retries needed; no compile blockers.

## Results
- Compile: clean under `--warnings-as-errors` (exit 0).
- Tests: **10 properties, 324 tests, 0 failures, 5 skipped** (Finished in 24.0s; 2.9s async, 21.1s sync).

## Observations (non-fatal)
- Test-run diagnostics emitted non-fatal type warnings from
  `AshPPlan.Reactor.Durable.Mutation.Migration.classify/3` (including an
  `if orphans != [] do false else false end` always-false-dynamic branch).
  These appear at test-run time (nofile evaluation) and did not trip
  `--warnings-as-errors` on compile. Pre-existing, not session-introduced.
- Protocol-court admissions witnessed: tla-rs v0.11.1 admitted
  JobLeaseProtocol (states 40, transitions 88, depth 7); mutants
  `claim_free` and `record_once` refused with witnessed counterexamples;
  stateright cargo vocabulary witness green.

## Standing
ALIVE (durable suites pass on this exact working tree; 5 skipped noted,
0 failures).

## Cleanup
- `_build-gate-dur` deleted after run.
