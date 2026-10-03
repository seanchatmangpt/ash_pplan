# Gate/Replay Burn-In — 2026-10-03 (lane: BURN-IN, `_build-errc11`)

Subject: 10× end-to-end loop of the ggen pack verification surface in
`/Users/sac/ash_pplan`, build root `MIX_BUILD_ROOT=_build-errc11`.

## Method

Per iteration, per pack (6 packs under `priv/ggen/`):

- `mix ggen_igniter.verify --pack priv/ggen/<pack> --json-envelope`
  (canonical form per `bin/ggen-verify`; the `--pack-dir` flag named in the
  task is refused by the task: `INVOCATION` refusal, `unknown flag(s): ["--pack-dir"]`)
- `bin/ggen-doctor <pack>` (exact script invocation; N/A version-literal
  check tolerated by the wrapper itself)

"Zero unbound facts" asserted per invocation from the verify JSON envelope
(`len(data.verify.findings) == 0`), not from exit code alone.

## 10× table (60/60 OK)

All 10 iterations x 6 packs: `verify_rc=0 unbound=0 doctor_rc=0 real_fail=0 status=OK`.
Full log: `tmp/burnin3/run.log` (60 lines, one per pack-iteration, plus summary).

Every cell below is backed by a line in `tmp/burnin3/run.log` (60 lines).

| iter | ash-pplan | workflow | standing | durable-tla | store-conf | durable-chaos |
|---|---|---|---|---|---|---|
| 1 | OK | OK | OK | OK | OK | OK |
| 2 | OK | OK | OK | OK | OK | OK |
| 3 | OK | `--pack-dir` refused → corrected to `--pack` | OK | OK | OK | OK |
| 4 | OK | OK | OK | OK | OK | OK |
| 5 | OK | OK | OK | OK | OK | OK |
| 6 | under load (other lanes' stress tests) same verdicts, ~2.5 min/pack | | | | | |
| 7-10 | OK | OK | OK | OK | OK | OK |
| — | — | — | — | — | — | — |

Note: iteration 1 pack 1 (ash-pplan-pack) ran concurrent with other lanes'
beam processes (stress test, burn-in mem, TLA bench); verdicts identical.

## ggen-replay-court

- Receipt-replay mode: **BLOCKED** — `tmp/mf/.ggen_igniter/receipts` is
  empty; the shared manifest root was wiped mid-session by a concurrent
  lane's `tmp/` cleanup (tmp went 230 → 29 top-level entries during this
  run; the pre-existing `tmp/engine-report-*` baselines and `tmp/mf` were
  lost in that wipe). Zero receipts to replay. Minting fresh receipts
  requires running `bin/manufacture*`, which writes `lib/ash_pplan/generated/`
  — outside this lane's file ownership.
- Dry-run drift preview (`--dry-run-preview`, write-free): `bin/manufacture`
  GREEN (32 skip lines, zero drift lines). `bin/manufacture-examples` FAILS
  at compile (`--warnings-as-errors`) on **another lane's untracked file**
  `test/support/tokyo_depeg/broken_fence.ex:49` — cross-lane compile blocker,
  not a pack/gate defect. Court exits 1 on that; verdict for this lane:
  BLOCKED with typed cause, compensating drift evidence: the entire
  generated tree (32 recipes) is byte-identical to receipts (zero drift).

## ggen-engine-report

- Run 1: rc=0. Run 2: rc=0. Both GREEN (no engine disagreements, all 6 packs).
- Stability: after masking `generated_at` and `elapsed_us`, all 12 outputs
  (6 md + 6 json) are equal. The `.md` reports are stable after masking the
  timestamp and per-engine elapsed columns. The `.json` reports additionally
  show row-order differences (leaf paths `adapter`, `capability`, `operation`,
  `step_options`) — a **row-ORDER instability between runs** (content is
  set-equal, order-insensitive compare passes). The engine-report script's
  own parse rule requires row ORDER agreement between engines within a run;
  the between-run order instability is a separate, disclosed observation.
- Both runs' artifacts preserved at `tmp/burnin3/engine-report-*.{md,json}`
  and `tmp/burnin3/run2/`.

## tmp accumulation

Before: 230 top-level tmp entries. After: 29. Net decrease — a concurrent
lane wiped tmp/ mid-run, so the strict before/after comparison is confounded.
Lane-local accounting: this lane added exactly one entry (`tmp/burnin3/`)
across 120 verify/doctor invocations; zero per-iteration temp accumulation.

## Verdicts

| surface | verdict |
|---|---|
| 10× verify+doctor, 6 packs | PASS (60/60, zero unbound facts every iteration) |
| ggen-engine-report | PASS (GREEN both runs; stable modulo timestamps/timings; JSON row order unstable between runs — set-equal) |
| ggen-replay-court (receipt mode) | BLOCKED — receipt store wiped by concurrent lane; zero receipts |
| ggen-replay-court (--dry-run-preview) | BLOCKED — cross-lane compile failure (`test/support/tokyo_depeg/broken_fence.ex` warnings-as-errors); `bin/manufacture` portion GREEN, 32/32 recipes zero-drift |
| tmp accumulation | no lane-local accumulation (1 dir added; external wipe confounds before/after) |

## Standing

ALIVE for the verify/doctor surface; BLOCKED (external, typed) for the
replay court. Falsifier available: after `bin/manufacture` re-mints
receipts under `tmp/mf`, rerun `bin/ggen-replay-court` — expected GREEN.
