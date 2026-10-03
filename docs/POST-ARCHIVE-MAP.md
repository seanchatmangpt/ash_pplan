# Post-Archive Map — next work for ash_pplan (2026-10-03)

Baseline: `dd9024d` (freeze: kill-storm courts green x12; unique-integer sweep; dets fixes).
The archived map `docs/COMBINE-HARDEN-MAP.md` is fully RESOLVED; every item below is new
or was left explicitly open by that map's receipts. Repo scanned fresh at 16 commits
ahead of `origin/main`, zero TODO/FIXME/XXX/HACK markers in `lib/`+`test/` (re-checked).

Classifications: COMBINE / HARDEN / CLEANUP / VERIFY / PERF.
Public API surface of the modules touched by these items:
`docs/diataxis/reference/public-api.md`. Scope: S (<1 lane-day),
M (1–2 lane-days), L (multi-day / multi-wave).

## Prioritized action list

### P1 — VERIFY — first CI run of the bench gate (S)
- **Evidence**: `.github/workflows/ci.yml:138-146` (Bench gate step runs
  `./bin/bench bench/store_scaling.exs --force`); `receipts/wave2-integration-receipt-2026-10-03.md:252`
  — "CI bench gate: STILL UNEXERCISED IN CI … the next pushed `main` run is its first proof (open follow-up)".
- **Action**: push the 16 unpushed commits to `origin/main`, observe the full CI run to
  green (all jobs, incl. bench gate, TLC court, SHACL conformance). Record the first-ever
  CI bench-gate receipt. If the bench gate flaked or overran the job timeout, tune the
  gate size in `bin/bench` / `bench/store_scaling.exs`.
- **Why first**: 14+ commits of landed waves have zero CI-witnessed runs; every ALIVE
  claim currently rests on local ladders only.

### P2 — HARDEN — fuzz/hardening courts for never-fuzzed surfaces (M)

**Status: COMPLETED** (2026-10-03, working tree — uncommitted). Courts landed:
`test/hardening/{compiler_options_matrix,state_machine_charts_fuzz,authority_ceiling_fuzz,sa2a_replay_fuzz,policy_offers_fuzz}_test.exs`.
- **Evidence**: fuzz courts today cover only control_plane, receipts, status, sa2a_refusal
  (`test/hardening/{control_plane,receipts,status,sa2a_refusal}_fuzz_test.exs`).
  Never fuzzed: `compiler/` partial-eval options surface (`lib/ash_pplan/compiler.ex`,
  options hardening exists as `test/hardening/compiler_options_hardening_test.exs` but is
  not a fuzz court), `workflow/` projection surface partially
  (`test/hardening/workflow_projection_hardening_test.exs`),
  `state_machine/charts.ex` (31 lines, unit-tested only via
  `test/state_machine_charts_test.exs`), `policy_closure/authority_ceiling.ex` (4 lines, single test),
  `sa2a/replay.ex` (76 lines, unit tests only), `fond/policy_supervisor/offers.ex` (no test at all).
- **Action**: add property/fuzz courts for: compiler options matrix (invalid option values,
  unknown options, adversarial specs), `StateMachine.Charts` (invalid chart terms), 
  `SA2A.Replay` (malformed bundles, truncated chains), `Fond.PolicySupervisor.Offers`
  (offers under kill/timeout), `AuthorityCeiling.admit/1` (all non-member atoms).
  Chicago-style: real specs/stores, assert on final state.
- **Why**: the wave-2 fuzz courts each found real defects; same generation of surfaces
  remains unprobed.

### P3 — PERF — Merkle-style receipt identity (M–L)

**Status: LANDED** (2026-10-03, working tree — uncommitted). `AshPPlan.Standing.Cached`
identity is now Merkle-style (`ash-pplan-standing-identity-v2`, per-event leaf hashes +
bounded leaf memo); the falsifier re-run on `bench/receipt_cached_scaling.exs` and the
`BASELINES-CANONICAL.md` refresh are the remaining open residue.
- **Flagged twice** in `bench/STANDING-CLOSURE-BASELINE-2026-10-03.md:361` and `:465`:
  "the hit path IS the identity hash … a Merkle-style or projected identity would flatten
  the hit floor for 10k-event runs" (hit path = 96–104% of hit cost is
  `term_to_binary`+sha256 over the full run term; ~16–17 ms at 10k events).
- **Action**: per-event hashing + Merkle combine in `AshPPlan.Standing.Cached` identity
  (`lib/ash_pplan/standing/cached.ex`),
  incremental identity for append-only evidence; re-run
  `bench/receipt_cached_scaling.exs` and update `bench/BASELINES-CANONICAL.md`.
- **Falsifier**: identity cost at 10k events does not drop sub-linearly, or cached vs raw
  receipts stop being byte-identical (must stay byte-identical per `Standing.Cached` contract).

### P4 — PERF — OCEL events/export full-scan (M)

**Status: COMPLETED — PARTIAL** (2026-10-03, working tree — uncommitted). Sort-once +
max-from-tail in `lib/ash_pplan/reactor/durable/ledger_ocel.ex` and the mixed read/write
kill court in `test/stress/ocel_export_kill_test.exs` (+219 lines) landed; the full
O(1)-snapshot export and the 100k drift re-bench remain open.
- **Evidence**: `lib/ash_pplan/reactor/durable/ledger_ocel.ex:20` (`events/3` sorts the
  full standing list by `seq` on every call, `ledger_ocel.ex:52`), `:95` (`export/3` maps
  the full list; `:119` `max_seq/1` is a full `Enum.max` scan). Bench verdict
  (`bench/OCEL-SCALING-2026-10-03.md`): export drift 82.3% — NOT-LINEAR; events drift 29.2% — NOT-LINEAR.
  Concurrency surface: `export/3` reads without a store lock (kill court
  `test/stress/ocel_export_kill_test.exs` has a single test).
- Expand `test/stress/ocel_export_kill_test.exs` to a real concurrency court (concurrent
  export during checkpoint writes, mixed read/write kill-race) and add a snapshotted
  `:ets` read (single `:ets.tab2list`/lookup plan) to make export O(1)-snapshot instead of
  O(n) sort-per-call. Keep the OCEL2-JSON envelope byte-identical (assert digest equality
  on a fixture).
- **Falsifier**: export drift stays >25% at 100k, or any digest differs after the change.

### P5 — COMBINE — adopt the four notes' unacted recommendations (M)

**Status: LANDED (working tree; uncommitted)** (2026-10-03 P5 lane: schema regex + ontology + regenerated Standing.Receipt/Chain carry COMPENSATED/COMPENSATION_FAILED; receipt evidence digests `sha256:` prefixed; ExecutionReceipt carries repo/subject_sha/base_sha with `validate_identity/1`; SA2A supports?/1 duplication court added; ferroplan boundary + OCEL canonical-envelope direction recorded in docs/architecture.md.)
- **Evidence**: all four 2026-10-03 notes carry recommendations with zero follow-on commits
  (`git log --grep` confirms no action commits after the notes landed).
  - `notes/ocel-vocabulary-audit-2026-10-03.md`: xaas OCEL envelope convergence: ash_pplan's
    `ProcessEvidence.export/2` is named the closest-to-spec envelope; the concrete local
    action is publishing it as the canonical envelope + generating the vocabulary registry
    from one RDF ontology (per dfcm-composition G: ontology→code).
  - `notes/receipt-schema-diff-2026-10-03.md:105-125`: extend canonical standing regex with
    `COMPENSATED`/`COMPENSATION_FAILED`; adopt `repo` + 40-hex `subject_sha`/`base_sha`
    cross-repo identity (C21 precondition); unify all digests to `sha256:<hex>` prefixed
    (BLAKE3 stays flagged-by-algorithm-field only).
  - `notes/sa2a-adapter-verdict-2026-10-03.md:31-35`: the `supports?/1` duplication —
    `AshPPlan.SA2A.Capability.supported/0` `[:fond, :powl]` duplicated as a hardcoded list
    in the consumer adapter; if the owner adds a formalism the consumer silently narrows.
    Concrete action: owner-side capability discovery or a court asserting the two lists match.
  - `notes/ferroplan-fond-verdict-2026-10-03.md`: synthesis ownership stays here; no move — record
    the boundary in docs/architecture.md (S).
- **Action**: one COMBINE lane per note action; schema-regex extension is the smallest
  first step (S).

### P6 — HARDEN — DSL verifier/transformer gap (M)

**Status: COMPLETED** (2026-10-03, working tree — uncommitted).
`test/workflow/dsl_verifiers_court_test.exs` covers all four verifiers + transformer
invariants; the OutcomeClosure documented-vs-implemented finding corrected the moduledoc.
- **Evidence**: all four DSL verifiers and the transformer have no dedicated tests:
  `lib/ash_pplan/workflow/dsl/verifiers/{outcome_closure,acyclic_dependencies,capabilities_parse,unique_ids}.ex`
  and `lib/ash_pplan/workflow/dsl/transformers/generate_model.ex` — exercised only
  transitively through `test/workflow/dsl_test.exs`. Add targeted courts: unresolvable
  outcome ref, dependency cycle, unparseable capability, duplicate id, transformer output
  invariants.
### P7 — VERIFY — module→test gap closure for generated/ and adapters/ (S–M)

**Status: COMPLETED** (2026-10-03). `docs/jira/coverage-index-2026-10-03.md` — module→covering-test
table on the post-rename tree (138 modules; 3 uncovered named); supersedes the stale "34 modules" scan figure.
- **Evidence**: 34 lib modules with no name-matching test file
  (full list captured in the scan; highest-value: `generated/plan_catalog.ex`,
  `generated/projection_catalog.ex`, `generated/workflow/capability_catalog.ex` (has court via `test/workflow/workflow_regeneration_court_test.exs`), `fond/supervision_session.ex`,
  `fond/counterexample.ex`, `fond/consumer.ex`, `fond/provider_registry.ex`,
  `reactor/adapters/*` (ash_reactor, bb_reactor, reactor_file, reactor_process, reactor_req)
  covered only via `test/workflow/reactor_adapters_test.exs`, `reactor/durable/{key,clock,records,checkpointed,child_error}.ex`.
- **Action**: for each, either (a) name the court that already covers it (many generated/
  modules are projection outputs covered by regeneration court) or (diverse) add a minimal
  smoke court. Output: a table module → covering test, committed as
  `docs/jira/<milestone>/_LANES.md`-adjacent coverage index, or fix.
- **P7 falsifier**: a module in `lib/` with no covering court and no coverage-index entry.

### P8 — CLEANUP — untracked scratch dirs (S)

**Status: COMPLETED — PARTIAL** (2026-10-03). `test/hardening/dets_read_no_sync_test.exs` committed
@ `5d80623` and the map-pointer edit to `docs/COMBINE-HARDEN-MAP.md` landed; the scratch dirs
(`.clap-noun-verb/`, `notes/reclaimed-home/`, `priv/ggen/.ggen_igniter/`) still need the
admitted-transition decision.
- `?? .clap-noun-verb/`, `?? notes/reclaimed-home/`, `?? priv/ggen/.ggen_igniter/` are
  untracked at scan time; and `test/hardening/dets_read_no_sync_test.exs` is a new
  untracked test not yet committed. Decide per file: commit the test, gitignore or delete
  the scratch dirs (per same-checkout cleanup law: cleanup is an admitted transition —
  plan → approve → delete with receipt).
- Also update `docs/COMBINE-HARDEN-MAP.md` header to point at this map (pointer only).

### P9 — VERIFY — DETS repair-wait re-verify (S)

**Status: COMPLETED** (2026-10-03). `receipts/dets-repair-reverify-2026-10-03.md`:
12 tests, 0 failures across the four DETS courts on `_build-p89`; subject post-freeze `5d80623`.
- `bench/STANDING-CLOSURE-BASELINE-2026-10-03.md` note: a lane fixed forward a pre-existing guard
  bug in `lib/ash_pplan/reactor/durable/store/dets.ex` (`repairable?/1` inside a guard)
  and asked "the owning lane should re-verify the DETS repair-wait path" — no follow-up
  receipt exists. `test/hardening/{dets_crash_court,dets_reopen_retry,dets_read_no_sync}_test.exs`
  and `test/stress/dets_burn_in_test.exs` are the relevant courts; run them on the current
  build and write the re-verify receipt.
- Also: `M test/stress/checkpoint_burst_kill_test.exs` and
  `M test/tokyo_depeg/actuation_boundary_test.exs` are modified-but-uncommitted; commit
  or revert in the P8 cleanup transition.

**Not carried over**: the old map's COMBINE items (overlapping surfaces, scattered notes
consolidation, CLEANUP inventory) — all RESOLVED in waves through `dd9024d`.

## Scope summary

| # | Item | Class | Scope | Status (2026-10-03 post-archive wave) |
|---|------|-------|-------|----------------------------------------|
| P1 | CI bench gate first run | VERIFY | S | OPEN |
| P2 | fuzz courts for never-fuzzed surfaces | HARDEN | M | COMPLETED (working tree; uncommitted) |
| P3 | Merkle receipt identity | PERF | M–L | LANDED (working tree; uncommitted) |
| P4 | OCEL export snapshot + concurrency court | PERF/HARDEN | M | COMPLETED — partial (sort-once/max-tail + mixed kill court; full O(1) snapshot not yet) |
| P5 | adopt notes' recommendations | COMBINE | M (regex S) | LANDED (working tree; uncommitted) |
| P6 | DSL verifier courts | HARDEN | M | COMPLETED (working tree; uncommitted) |
| P7 | coverage index for no-test modules | VERIFY | S–M | COMPLETED (`docs/jira/coverage-index-2026-10-03.md`) |
| P8 | untracked/modified scratch cleanup | CLEANUP | S | COMPLETED — partial (dets_read_no_sync committed @ `5d80623`; scratch dirs uncommitted) |
| P9 | DETS repair-wait re-verify | VERIFY | S | COMPLETED (`receipts/dets-repair-reverify-2026-10-03.md`; court committed @ `5d80623`) |
