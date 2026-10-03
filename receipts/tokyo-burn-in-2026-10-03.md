# Receipt: Tokyo-Depeg Burn-In Runner (plan W4)

- Date: 2026-10-03
- Repo: /Users/sac/ash_pplan (no git lane ops; MIX_BUILD_ROOT=_build-tdb-w4)
- Runner: `bin/tokyo-burn-in` (wrapper) + `bin/tokyo_burn_in_runner.exs` (new, W4)
- Env: OTP 28, Elixir 1.19.5, MIX_ENV=test, macOS Darwin 25.2.0

## Standing

- Plan W4 required the burn-in runner; `bin/tokyo-burn-in` did not exist at start of
  session (checked bin/ first). Built against real lib/ APIs. It consumes
  `AshPPlan.Test.{DurableFx, Effects, FONDFixture}` from test/support (compiled by
  `elixirc_paths(:test)`), so it depends on the test-env build being whole — the
  W2-rendered modules were NOT needed; no stub was used.

## What the runner does

N cycles x C concurrent order flows through the real stack, mirroring
`test/stress/tokyo_pipeline_stress_test.exs`:

`SA2A.Provider.propose/2` (real FOND) -> `Engine.start/attempt` on `Store.Dets`
-> park on the `human_release` signal -> deliver signal -> resume to `:completed`
-> `LedgerOCEL.digest/events` (receipt evidence) -> `Standing.verdict/3`.

Store is hard-killed (`Process.exit(pid, :kill)`, untrappable) between cycles; only
per-call `dets.sync/1` guarantees durability. Adapter registered directly via
Application env (no ExUnit on_exit in a runner process).

## Falsifier courts (exit 0 only if all fired green)

- F1 exactly-once effects: admit/authorize/commit counters == cumulative total, never above
- F2 seq monotonicity: unique and strictly increasing within and across kills
- F3 zero lost runs: every run present and `:completed` after the final reopen
- F4 OCEL digest continuity: pre-kill digests byte-identical after kills
- F5 standing composition: `Standing.verdict/3` == `:alive` per flow

## Run 1 (bounded): --cycles 4 --concurrency 16

Per-cycle (flows, wall ms, orders/s):

| cycle | ms | orders/s |
|---|---|---|
| 1 | 1774 | 9.0 |
| 2 | 1475 | 10.8 |
| 3 | 1212 | 13.2 |
| 4 | 2542 | 6.3 |

Total 64 flows, 7051 ms (9.1 flows/s). Memory deltas: processes +0.1 MB, ets +0.1 MB,
total +2.0 MB. All courts GREEN. EXIT=0.

## Run 2 (soak): --cycles 8 --concurrency 32

Per-cycle:

| cycle | ms | orders/s |
|---|---|---|
| 1 | 3983 | 8.0 |
| 2 | 3699 | 8.7 |
| 3 | 8978 | 3.6 |
| 4 | 8140 | 3.9 |
| 5 | 6238 | 5.1 |
| 6 | 4976 | 6.4 |
| 7 | 8971 | 3.6 |
| 8 | 14983 | 2.1 |

Total 256 flows, 60 019 ms (4.3 flows/s). Memory deltas: processes -5.9 MB,
ets +0.1 MB, total -6.1 MB (no leak; flat ~41 MB process, ~2.1 MB ets). All courts
GREEN. EXIT=0.

## Output tails (real)

Run 1:

```
F1_exactly_once_effects: GREEN
F2_seq_monotonic: GREEN
F3_zero_lost_runs: GREEN
F4_ocel_digest_continuity: GREEN
F5_standing_composition: GREEN
[burn-in] VERDICT: ALIVE
EXIT=0
```

Run 2:

```
[burn-in] cycle 8: 32 orders in 14983 ms (2.1 orders/s), seq high-water 1376 ...
F1..F5 all GREEN
[burn-in] VERDICT: ALIVE
EXIT=0
```

## Deviations caught (observations, not court failures)

1. `seq` high-water advances by ~6x the flow count per cycle (e.g. +192 for 32 flows),
   so seq is allocated per store mutation (checkpoints/signals), not per run. Monotonic
   and unique as required; worth knowing when reading seq-based courts elsewhere.
2. Per-cycle throughput degrades as the DETS file grows (8.0 -> 2.1 orders/s over 8
   cycles at C=32), consistent with reopen/rescan cost on the growing file, not a
   per-op regression: cycle-1 shapes repeat at ~8/s at both C=16 and C=32.
3. Session-introduced fix to unblock the test-env compile (pre-existing broken file,
   not from this lane): `test/support/tokyo_depeg/refusals.ex` used string literals in
   a typespec union (`| "REFUSED_AUTHORITY_REVOKED"`), which Elixir rejects. Loosened
   to `@type code :: atom() | String.t()` with the closed set still defined by `@codes`
   and enforced by `hardening_test.exs`. No consumer relied on the narrow type.
4. Pre-existing warnings in test/support/tokyo_depeg/{alignment,affidavit,broken_fence}.ex
   (unused vars, duplicate @doc) are another lane's surface; untouched.

## Replay

NOTE on the `bin/tokyo-burn-in` name: mid-session, another lane's ggen scaffold
(`packs/tokyo-depeg-burn-in-pack`) landed a GENERATED `bin/tokyo-burn-in` whose
`run_once/1` is a vacuous `:pass` and whose kill policy is a no-op — it has NOT been
falsified by a real run. The runner receipted here is `bin/tokyo_burn_in_runner.exs`
(real propose/Engine/signal/receipt pipeline), replayed as:

```sh
cd /Users/sac/ash_pplan
MIX_BUILD_ROOT=_build-tdb-w4 MIX_ENV=test \
  mix run bin/tokyo_burn_in_runner.exs --cycles 4 --concurrency 16   # EXIT=0
MIX_BUILD_ROOT=_build-tdb-w4 MIX_ENV=test \
  mix run bin/tokyo_burn_in_runner.exs --cycles 8 --concurrency 32   # EXIT=0
```

(A third replay of run 1 via `mix run` after the name collision: 64 flows,
14 208 ms, 4.5 flows/s, all courts GREEN, EXIT=0.)

Verdict: ALIVE for `bin/tokyo_burn_in_runner.exs` (all falsifiers fired green across
three real runs; exit-0 rule honored). The generated `bin/tokyo-burn-in` stub is
UNKNOWN, not ALIVE.
