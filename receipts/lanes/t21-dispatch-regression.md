# Lane T21 — pplan dispatch durability regression (seal-blocking)

Standing: PARTIAL_ALIVE

## Charter
Reproduce + fix the durability court's "dispatch effects never execute
(prepare/finish 0)" regression in path mode; land an in-repo regression court
in ash_pplan test/durable/.

## Root cause (honest, lower-confidence than the court results)
The court flipped 4/4 FAIL → 4/4 PASS between my run 1 and run 2 while the
shared ash_pplan tree carried heavy concurrent lane WIP (W1-W6/A3/A4/T2 in
lib/ash_pplan/reactor/durable/). Between the runs the only delta on my side
was a no-op `tap/2` probe (added then removed, restore verified byte-exact
via `diff /tmp/ckpt.bak`); the durable stack itself was being recompiled from
a settling WIP tree. Evidence the composed law (intent-before-effect in
`Checkpointed.run_inner` + strict pending-signal-gated `take_signal` in
`Store.Dets`) is correct: instrumented run traced the full dispatch shape —
prepare executes with `durable_intent_token` in ctx → await parks with waiter
"go" → take_signal consumes pending → finish executes once — plus the a2a
court and my new in-repo court both hold 4/4 and 2/2 stable across repeat
runs. Diagnosis of the run-1 failure class: torn mid-flight compile window of
the in-flight tree, healed by subsequent lane edits. UNVERIFIED which specific
concurrent edit healed it (candidate: W2's strict take_signal / F16's intent
composition settling); no defect in the landed composition was found.

## Fix
No ash_pplan product-code change required. Landed:
- test/durable/dispatch_durability_test.exs (NEW, untracked — coordinator
  must `git add` explicitly; untracked-evidence = CI-red law) — reproduces
  the a2a dispatch shape: Engine.start → attempt parks on Await after prepare
  executes exactly once keyed on `context.durable_intent_token` → delivery
  resumes → finish exactly once → one run, tape 3, terminal attempt :ended.
  Second test pins the token adopt law: same (run id, step) re-executes under
  the SAME token across a fresh store (adopt, not re-mint); different run id
  → different token.
- Anti-vacuity witnessed: mutation skipping `Run.record_intent` flips the new
  court 2/2 FAIL; restore byte-exact, court back to 2/2 PASS.

## Commands / exits
- a2a court path mode: `cd /Users/sac/ash_a2a && ASH_PPLAN_PATH=/Users/sac/ash_pplan
  MIX_BUILD_ROOT=_build-laneT21 MIX_ENV=test mix test
  test/execution/pplan_dispatch_durability_test.exs --include serial`
  → first run: 4 tests, 4 failures (prepare/finish 0, reproduced T11's census);
    final run: 4 tests, 0 failures (×3 stable incl. no-probe runs)
- new court: `MIX_BUILD_ROOT=_build-laneT21 MIX_ENV=test mix test
  test/durable/dispatch_durability_test.exs --include serial` → 2 tests, 0 failures
- mutation: 2 tests, 2 failures (flips — non-vacuous), restore exact
- full `mix test test/durable/` (lane root): 10 properties, 438 tests,
  2 failures, 1 skipped — the 2 failures are PRE-EXISTING on the WIP tree,
  NOT mine (verified: fail in isolation; both in
  test/durable/store_conformance_dets_test.exs anti-vacuity:
  (1) mutant TakeSignalAdoptRegardless "was not caught by law
  take_signal_atomic"; (2) "ontology callbacks equal the Store behaviour's
  callbacks" — left missing `take_signal: 7`. Same W2/store-conformance
  surface; hand to the coordinator — did not touch another lane's in-flight
  files.)

## Court results
- ash_a2a durability court (path mode): 4/4 PASS (reproduced the 4/4 FAIL
  first; the T11 census failure class no longer reproduces on the settled tree)
- ash_pplan regression court: 2/2 PASS, mutation-flippable

## For the coordinator
- git add test/durable/dispatch_durability_test.exs explicitly (never -A).
- Pre-existing reds to route: store_conformance_dets anti-vacuity ×2 (W2
  surface). F16/T10 lane receipts absent from ash_a2a receipts/lanes/ as of
  this lane's close (only a10/f2/t11/z11/z18 present).
- Session-introduced warnings in my file: none remaining (adapter @impl +
  attribute scoping fixed during bring-up).
