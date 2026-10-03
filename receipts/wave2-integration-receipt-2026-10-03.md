# Wave-2 Integration Receipt — 2026-10-03

# COMMITTED as `c60b45b` (2026-10-03)

Committed as `c60b45b` "wave-2: standing receipt cache + fleet hardening courts
+ burn-in evidence" (95 files, +9506/−1039) on branch `main`. Post-commit
follow-up wave landed as `e4e67e1` (release-gate fixes + fuzz courts). Gate
closure evidence: `docs/COMBINE-HARDEN-MAP.md` wave-2 block (gate CLOSED, all
eight items RESOLVED) and the `c60b45b` commit message Gates line — full
pre-commit ladder: format PASS (35 files), `compile --warnings-as-errors`
clean, scoped suites 295/295, dets burn-in 12/12 on canonical `_build`.

Gate conditions from the original banner, resolved:

1. `test/stress/dets_burn_in_test.exs` on canonical `_build/` — **SATISFIED**
   (12/12, per the `c60b45b` gates line and map-doc gate closure).
2. `test/burn_in/dets_reopen_soak_test.exs` (30-cycle soak) — **SATISFIED**
   (included in the dets suites 12/12 pre-commit ladder; the "dets hang" was
   root-caused as a missing base-case guard in the burn-in test loop, not lib).
3. Stress/burn suites re-run green on canonical `_build/` — **SATISFIED**
   (per `c60b45b` gates line: storm 0 faults, LRU bound exact 256/256;
   re-witnessed post-commit 2026-10-03: `mix test
   test/stress/receipt_cached_storm_test.exs` → 1 test, 0 failures,
   cache size final 256/256, faults: 0).
4. Standing cache LRU bound (was OPEN) — **SATISFIED / FIXED**: the fix landed
   in `lib/ash_pplan/standing/cached.ex` (eviction-lock serialized
   `evict_until_under_bound/0` before every growing insert; single-flight
   `await_flight/4` with bounded extension + dead-holder takeover). The
   earlier "overbound not present in the tree" note is superseded — the fix
   predates this note's reading of the tree; storm court confirms bound
   exactness.
5. No `_build-*` lane lease dirs left at integration — **SATISFIED**
   (49 stale roots purged, 24.26 GiB reclaimed; map doc item 1 RESOLVED).

Still genuinely OPEN (unchanged):

- CI bench gate first committed run: no CI run exists at or after `c60b45b`
  (latest `main` run 37103923440 predates it and failed on the pre-wave tree);
  remains UNKNOWN until the next pushed `main` run.

Post-commit gate repairs (folded as `3e46c7c` "release-gate fixes: pack
provenance files, receipt clause order, format", 2026-10-03): the release
manufacture gate was unblocked by converting the `ash-pplan-pack` and
`ash-pplan-workflow-pack` root symlinks to real provenance-stamped ontology
files (ggen_igniter >= 26.10.1 refuses pack-root-escaping symlinks), and the
receipt gate by fixing `digest/1` clause order in
`lib/ash_pplan/execution_receipt.ex` (the catch-all was shadowing the
`{:halted, reactor}` clause). Gates at the fold: manufacture exit 0 (37 syncs
unchanged), `release_contract` 37/37, format PASS. The OPEN CI-bench-gate tail
above is unchanged by this commit.
- The compile warning noted at `await_flight` (`send_after` contract) is
  resolved: `compile --warnings-as-errors` passed in the pre-commit ladder.

## Subject

- Repo `/Users/sac/ash_pplan`, branch `main` @ `e404774` ("bench + receipts:
  replayable baselines and wave receipts"), uncommitted wave-2 working tree.
- Aggregate of the second hardening wave: dets path-lock livelock fix, DETS
  kill-race court fixes, typed-refusal hardening across state machine / workflow /
  providers, standing ladder dedup, `Standing.receipt_cached/2` + `Standing.Cached`,
  stress/burn suites, bench baselines, CI bench gate, CHANGELOG fold.

## Enumerated wave-2 changes (git status / diff --stat, read-only)

Modified (37 files, +1376/−1044):

```
.github/workflows/ci.yml                          |   9 +
CHANGELOG.md                                      |  80 ++++-
README.md                                         |   2 +-
bench/STANDING-CLOSURE-BASELINE-2026-10-03.md     |  88 ++++
bench/STORE-SCALING-2026-10-03.md                 |  79 ++++
bench/burn_cycle_bench.exs                        |  44 ++-
bench/compiler_cost_curve.exs                     |  73 ++--
docs/COMBINE-HARDEN-MAP.md                        |  34 +-
docs/archive/README.md                            |   3 +
docs/demonstration.md                             |  24 +-
docs/dfcm-ash-extension-closure.md                | 182 ------ (deleted → docs/archive/)
docs/diataxis/README.md                           |  8 +-
docs/diataxis/explanation/cross-repo-vocabulary.md| 237 ++++---
docs/working-backwards-press-release-v26.9.6.md   |  13 - (deleted)
docs/working-backwards-press-release-v26.9.7.md   | 13 - (deleted)
ecosystem.lock.toml                               |   2 +-
lib/ash_pplan/action/run.ex                       |  12 -
lib/ash_pplan/generated/workflow/capability_catalog.ex |   2 -
lib/ash_pplan/providers/qualify.ex                |  36 +-
lib/ash_pplan/reactor/durable/store/dets.ex       |  22 +-
lib/ash_pplan/standing.ex                         |  53 ++-
lib/ash_pplan/state_machine.ex                    |   6 +
lib/ash_pplan/workflow/model.ex                   |   9 +-
lib/ash_pplan/workflow/project/hddl.ex            |   6 +-
mix.exs                                           |   2 +-
notes/*.md (3 audit notes rewritten)              | ~552 lines
test/hardening/providers_action_hardening_test.exs|  35 +-
test/hardening/state_machine_hardening_test.exs   | 74 +--
test/hardening/workflow_projection_hardening_test.exs | 2 +-
test/stress/* (5 files updated)                   | ~718 lines
test/support/fond_fixture.ex                      |  14 +-
```

(Ground truth is `git diff --stat` on the tree: 37 modified, 3 deleted, 30 untracked.)

Untracked (30 files/dirs), grouped:

- dets path-lock livelock fix subject: `lib/ash_pplan/reactor/durable/store/dets.ex`
  (tracked, modified) + court `test/hardening/dets_crash_court_test.exs` (new) +
  soak `test/burn_in/dets_reopen_soak_test.exs` (new).
- Standing cache: `lib/ash_pplan/standing/cached.ex` (new module),
  `test/standing/receipt_cached_test.exs`,
  `test/standing/cached_adversarial_test.exs`,
  `test/standing/cached_integration_test.exs` (new courts), stress
  `test/stress/receipt_cached_storm_test.exs` (new), benches
  `bench/receipt_cached_bench.exs`, `bench/standing_receipt_cache_probe.exs`
  + raw runs `bench/receipt_cached_raw{1,2}.json`,
  `bench/standing_receipt_cache_raw{1,2}.json`.
- New hardening courts: `test/hardening/compiler_options_hardening_test.exs`,
  `test/hardening/status_fuzz_test.exs`,
  `test/fond/tla_differential_edge_test.exs`.
- New stress suites: `test/stress/chain_seal_storm_test.exs`,
  `test/stress/receipt_cached_storm_test.exs`,
  `test/stress/sa2a_propose_isolation_test.exs`,
  `test/stress/store_differential_storm_test.exs`.
- Bench baselines: `bench/BASELINE-2026-10-03.md`,
  `bench/COMPILER-BASELINE-2026-10-03.md`
  + raw data (`burn_cycle_raw{1,2}.json`, `hot_paths_raw{1,2}.json`,
  `store_scaling{,_map6}_raw{1,2}.txt`).
- Misc new: `docs/archive/dfcm-ash-extension-closure.md` (moved),
  `notes/ferroplan-fond-verdict-2026-10-03.md`, `priv/ggen/.ggen_igniter/`,
  `.clap-noun-verb/`, `notes/reclaimed-home/`.

## Area evidence

### dets path-lock livelock fix

`lib/ash_pplan/reactor/durable/store/dets.ex` `claim_path_lock/1`: on a stale
slot (dead owner pid), the old code did a bare `:ets.insert` after the liveness
check — a bare insert can never lose an `insert_new` race, so two claimants could
both win and double-open; and after takeover the stale key still occupies the
slot so a bare `insert_new` can never succeed → witnessed livelock. Fix: purge the
dead owner's slot with `:ets.delete(tab, path)`, then `insert_new`; a loser
retries `claim_path_lock/1` (comment block in the diff documents the race
analysis). Court: `test/hardening/dets_crash_court "kill mid-burst"`. Verified
here: `mix test test/hardening/` → **183 tests, 0 failures** (3.4s). Soak court
`test/burn_in/dets_reopen_soak_test.exs` (30 kill/reopen cycles) exists but is
NOT run in this lane — UNKNOWN.

### DETS kill-race court fixes

`test/hardening/dets_crash_court_test.exs` (new, kill mid-burst: acked writes
intact, lock free, seq continues). Verified green in the hardening sweep below;
the expected crash-log noise in the tail (Task EXIT killed) is the court's real
kill, not a failure. Full kill-race fixer lane still in flight per the gate —
UNKNOWN until that lane reports.

### state_machine / workflow / providers typed refusals

- `lib/ash_pplan/state_machine.ex` (+6): typed refusals; gate
  `test/hardening/state_machine_hardening_test.exs` — green in sweep.
- `lib/ash_pplan/workflow/model.ex` (+9/−), `workflow/project/hddl.ex` (6),
  `generated/workflow/capability_catalog.ex` (2), `action/run.ex` (−12),
  `providers/qualify.ex` (36): per-file gates are the hardening suites
  (`providers_action_hardening_test.exs`, `workflow_projection_hardening_test.exs`,
  `compiler_options_hardening_test.exs`, `status_fuzz_test.exs`).
- Verified here: `mix test test/hardening/` → **183 tests, 0 failures, 3.4s**
  (tail captured 2026-10-03, seed 107341; a Task EXIT-killed log line is expected
  court noise from the kill court).

### Standing ladder dedup

`lib/ash_pplan/standing.ex`: `ladder/2` rungs are now derived from
`Map.fetch!(derivations, state)` over `Ladder.states()` — "Rung order is the
ladder's own, never re-encoded here." Combine item 4 (umbrella vs
`standing/ladder.ex` duplication) marked RESOLVED in
`docs/COMBINE-HARDEN-MAP.md`. Gate: standing suite — verified below.

### Standing receipt_cached/2 + Standing.Cached

- Implementation receipt: `bench/STANDING-CLOSURE-BASELINE-2026-10-03.md`
  ("Standing receipt result cache (2026-10-03, implementation receipt)"):
  ETS-backed LRU (256 entries), key = sha256 of `term_to_binary({run, opts})`,
  full-receipt value; hit = **188.9x faster (99.5%)**, 312,823 → 1,655 us/call;
  byte-identical to `receipt/2` (same digest `781343e6…`); miss overhead 1.06x
  faster than baseline (identity hash negligible).
- Verified here: `mix test test/standing/ test/standing_test.exs` →
  **54 tests, 0 failures** (0.6s). Court docstrings cover determinism,
  invalidation on different events, LRU bound + eviction order, cached errors,
  2-process same-key concurrency, single-flight dedup
  (`await_flight/3` at `lib/ash_pplan/standing/cached.ex:76` — note: this line
  emits a compile **warning** (send_after arity/message contract); fix or
  document before commit).
- Storm: `test/stress/receipt_cached_storm_test.exs` (16 procs × 400 iters, hot/
  warm/cold mix, courts: hot-key byte-identity, typed results only,
  `Cached.size/0` ≤ 256, heap < 50 MB, wall-clock bounded). Storm verdict:
  **UNKNOWN** — not run in this lane (stress tag excluded by scope).
- **LRU overbound finding (RESOLVED post-commit)**: the original overbound
  evidence (storm fault shape `{:cache_overbound, w, i, size}` at
  `test/stress/receipt_cached_storm_test.exs:197` + the adversarial court's
  insert-race note) is closed: the eviction-lock serialized
  `evict_until_under_bound/0` fix landed in
  `lib/ash_pplan/standing/cached.ex`, and the storm court now reports
  `cache size (final): 256/256`, `faults: 0` (re-witnessed 2026-10-03
  post-commit).

### Stress/burn suite verdicts

Not run in this lane (scope: cheap suites only). Files in the wave:
`test/stress/{dets_burn_in,engine_cancel_storm,fond_propose_storm,
multi_store_storm,standing_churn,chain_seal_storm,receipt_cached_storm,
sa2a_propose_isolation,store_differential_storm}_test.exs`,
`test/burn_in/dets_reopen_soak_test.exs`,
`test/burn_in/ocel_digest_endurance_test.exs`,
`test/burn_in/tokyo_mutant_churn_test.exs`. Verdicts: **UNKNOWN** pending the
canonical-`_build/` re-run required by the commit gate.

### Bench baselines

- `bench/BASELINE-2026-10-03.md`, `bench/COMPILER-BASELINE-2026-10-03.md`,
  `bench/STANDING-CLOSURE-BASELINE-2026-10-03.md`,
  `bench/STORE-SCALING-2026-10-03.md` — two-run tables with raw JSON/TXT kept
  at `bench/*_raw{1,2}.{json,txt}`; standing-closure baseline recorded at
  `dbeddf6`-era working tree, OTP 28 / Elixir 1.19.5 / macOS.
- Burn-cycle decay and store scaling measured against real Engine
  `start → claim → run → complete` (no mocks). Reproduce commands in each
  baseline file; raw data committed alongside.

### CI bench gate

`.github/workflows/ci.yml` (+9): new step "Bench gate (store scaling)",
`matrix.primary` only, 3-minute timeout,
`./bin/bench bench/store_scaling.exs /tmp/bench-gate.json --force` with
MIX_BUILD_ROOT=_build-bench own build root, exit != 0 fails the job. Replayable
via `bin/bench`. Not exercised in CI yet (uncommitted) — first proof will be the
wave-2 integration commit's CI run — UNKNOWN until that run.

### CHANGELOG fold

`CHANGELOG.md` (+80): wave-1+2 fixed entries folded (continuation capture,
Action.Run error returns, StateMachine capability derivation, AshOban trigger
classification, FOND validation/synthesis quadratic fix, receipt RDF control
chars, typed refusals for `execute/5`/`compile_spec/2`/`restore/3`). None of it
is committed; the fold is part of the same pending integration commit.

## Commit gate status (CLOSED at `c60b45b`)

- dets burn-in hang fix lane: **CLOSED** (12/12 on canonical `_build/`;
  root cause was a missing base-case guard in the burn-in test loop, not lib).
- Kill-race fixer: **CLOSED** (kill-race court green in the pre-commit ladder).
- Standing/hardening suites: **GREEN** (54/0 and 183/0 here; 295/295 scoped
  in the pre-commit ladder).
- Cache LRU bound: **RESOLVED** (fix in `cached.ex`; storm 256/256, 0 faults).
- CI bench gate: **STILL UNEXERCISED IN CI** — no CI run at/after `c60b45b`
  yet; the next pushed `main` run is its first proof (open follow-up).

## Receipt fields

- Subject: `/Users/sac/ash_pplan` working tree over `e404774` (uncommitted).
- Authority: integration-lane scope (write only this file); all evidence read
  from the tree or produced by scoped `mix test` runs.
- Consequence: one receipt file; zero lib/test edits; two scoped test runs
  (standing 54/0, hardening 183/0).
- Replay: `git diff --stat`; `MIX_BUILD_ROOT=_build MIX_ENV=test mix test
  test/standing/ test/standing_test.exs`; `MIX_BUILD_ROOT=_build MIX_ENV=test
  mix test test/hardening/`.
- Standing: PARTIAL_ALIVE — wave-2 areas are ALIVE on committed `c60b45b`
  (gates CLOSED); CI-bench-gate first run remains the open tail.

## Post-freeze validation (2026-10-03)

- DETS wedge soak: **0 wedges across 4 runs** of the kill-storm court
  (`test/stress/checkpoint_burst_kill_test.exs`), vs ~70 wedges/run on the
  pre-fix baseline (sync-per-op backlog). Fix: sync-on-write-only + 60s
  bounded calls + signal match-spec pushdown in `Store.Dets`.
- Standing churn: `test/stress/standing_churn_test.exs` **3/3 green**.
- Tokyo burn-in: **49/50** — one failure is a stale test pin (expected-value
  assertion lagging a lib fix, not a lib defect); fix in flight.
- Bench refreshes green: chain digest O(n)->post-fix receipt-cache scaling
  (honest hit speedups 14.6-29.1x, superseding the stale ~2100-2200x
  pre-chain-fix figures; `bench/STANDING-CLOSURE-BASELINE-2026-10-03.md`),
  store scaling post-wedge-fix (`bench/BASELINES-CANONICAL.md`), hot paths
  and burn-cycle baselines re-run PASS.
