# Changelog

## 26.10.3 - 2026-10-03 (unreleased additions)

### Added

- Case-study layer: canonical worked examples under `docs/case-studies/`, referenced
  from the README with the honesty contract (numbers cite receipts under `receipts/`;
  reproduction via `bin/case-study`); receipt line pending `bin/case-study` execution.
- Hardening test suites: `test/hardening/` (capability-policy and compiler/Oban hardening
  courts), `test/durable/{error_path,ledger_ocel,store}_hardening_test.exs`,
  `test/fond/fond_harden_h4_test.exs`, and `test/fond/fond_horizon_burn_test.exs`.
- Tokyo-depeg scenario courts and runner, test-only: the five stage courts under
  `test/tokyo_depeg/` (identity/fencing, envelope, conformance/alignment, actuation boundary,
  revocation receipt, hardening) backed by the `test/support/tokyo_depeg/` corpus (canonical
  JCS canonicalizer, alignment, affidavit, refusals, revocation support, generated stages);
  `docs/diataxis/explanation/tokyo-depeg-burn-in.md` and
  `docs/diataxis/how-to/run-the-tokyo-burn-in.md`.
- Bench/burn-in/stress artifacts: `bench/hot_paths_bench.exs`,
  `bench/standing_closure_bench.exs`, `bench/store_scaling.exs`,
  `bench/tdb_burn_in_bench.exs`, `bench/tokyo_stage_costs.exs` (plus their raw JSON results and
  baseline notes), `bench/README.md`, and the `bin/bench` entry point.
- Standing receipt cache: `AshPPlan.Standing.receipt_cached/2` and the
  `AshPPlan.Standing.Cached` LRU cache (eviction-lock serialized bound, exact
  256/256 under storm), with single-flight cold fills — concurrent same-key
  callers share one compute via `await_flight/4` claims with bounded extension
  and dead-holder takeover — giving a 188.9x hit-path speedup on that probe
  (`bench/standing_receipt_cache_probe.exs`); the post-chain-digest-fix
  scaling courts give the honest end-to-end hit speedups of 14.6-29.1x
  across cache sizes, superseding the stale ~2100-2200x pre-chain-fix
  scaling figures (addendum in
  `bench/STANDING-CLOSURE-BASELINE-2026-10-03.md`).
- Post-archive fuzz courts (P2): `test/hardening/compiler_options_matrix_test.exs`
  (compiler partial-eval options matrix), `test/hardening/state_machine_charts_fuzz_test.exs`
  (invalid chart terms), `test/hardening/authority_ceiling_fuzz_test.exs`
  (`AuthorityCeiling.admit/1` non-member atoms), `test/hardening/sa2a_replay_fuzz_test.exs`
  (malformed bundles, truncated chains), and `test/hardening/policy_offers_fuzz_test.exs`
  (`Fond.PolicySupervisor.Offers` under kill/timeout).
- Merkle-style receipt identity (P3): `AshPPlan.Standing.Cached` identity is now a
  domain-tagged sha256 over non-event fields + one sha256 leaf per evidence event
  (`term_to_binary` per event), with a bounded memoized leaf table so repeated identities
  over an append-only evidence ledger do not re-serialize unchanged events; cached vs raw
  receipts stay byte-identical (identity tag `ash-pplan-standing-identity-v2`).
- OCEL export perf + concurrency court (P4): `LedgerOCEL.export/3` sorts standing once and
  takes `max_seq` from the sorted tail (no second full pass), and
  `test/stress/ocel_export_kill_test.exs` grows a mixed read/write concurrency court
  (4 writers x 250 writes, 8 readers exporting during checkpoint writes, mid-flight kill,
  acked-prefix stability post-reopen) with per-export digest of a consistent prefix snapshot.
- DSL verifier court (P6): `test/workflow/dsl_verifiers_court_test.exs` — targeted refusals
  for unresolvable outcome refs, dependency cycles, unparseable capabilities, duplicate ids,
  and transformer output invariants; includes the documented-vs-implemented finding that
  `OutcomeClosure`'s moduledoc claimed "closure under the dependency relation" with no DSL
  referent — the moduledoc was corrected to the real closure property
  (`terminal_outcomes ⊆ outcomes`, enforced by `Model.validate/1`).
- Coverage index (P7): `docs/jira/coverage-index-2026-10-03.md` — re-scan of the P7 module→test
  gap on the post-rename tree (138 lib modules; 43 name-matched, 92 of 95 remainder covered by
  identified courts, 3 uncovered), superseding the map's stale "34 modules" figure.
- Fuzz courts: `test/hardening/control_plane_fuzz_test.exs` (garbage inputs
  over the composed control-plane view) and
  `test/hardening/receipts_fuzz_test.exs` (garbage reactors digested via
  `safe_intermediate_results/1`; `ReleaseReceipt` head refusals typed).
- Stress/burn-in suites: `test/stress/standing_churn_test.exs`,
  `test/stress/chain_seal_storm_test.exs`,
  `test/stress/sa2a_propose_isolation_test.exs`, and the ledger/OCEL endurance
  hardening (`test/durable/ledger_ocel_hardening_test.exs`), alongside the
  DETS burn-in, engine-cancel, FOND-propose, and multi-store storm tests.
- Compiler cost curve and burn-cycle baselines: `bench/compiler_cost_curve.exs`
  + `bench/COMPILER-BASELINE-2026-10-03.md`, `bench/burn_cycle_bench.exs` +
  `bench/BASELINE-2026-10-03.md`, and the standing-closure baseline refresh
  (`bench/STANDING-CLOSURE-BASELINE-2026-10-03.md`).
- Diataxis explanation page: `docs/diataxis/explanation/cross-repo-vocabulary.md`.
- Verdict notes: `notes/ferroplan-fond-verdict-2026-10-03.md` and
  `notes/sa2a-adapter-verdict-2026-10-03.md`.

### Fixed

- `Store.Dets` concurrent-open race: a node-local path lock refuses a second open of the same
  DETS file with `{:error, {:path_in_use, path}}` (DETS itself permits double opens); the lock
  table is owned by an unlinked daemon so its creator's death can no longer silently release
  every held lock, a dead owner's lock is taken over, and a failed open no longer traps exits
  into the caller; a takeover also purges the stale owner entry before re-inserting,
  so a takeover loop cannot livelock on the dead lock record.
- `Durable.Engine.signal/5` orphan-signal refusal: a signal for a run that does not exist
  (including non-binary run ids) returns `{:error, :no_such_run}` instead of storing an
  unconsumable row forever.
- `unwind_blocked -> unwind_blocked` is now a legal self-transition (a second failed rollback
  records its fresh error over the stale one), updated in `Status`, `priv/tla/durable/transitions.exs`
  and the durable-tla pack ontology (TLA surface regenerated).
- Standing/Ladder typed refusals: non-map runs, malformed events/gates, missing
  attributes/selection lookups, and unknown ladder layers are typed errors
  (`STL_malformed_run`, `R_unknown_layer`, `R_missing_identity`, `{:malformed_event, _}`,
  `{:malformed_gate, _}`) instead of crashes; selection lookup never synthesizes atoms from
  event data.
- Typed refusals at the control-plane boundaries: `Oban.describe_resource/activations/
  capabilities/fetch_activation` and `Providers.Resolver.resolve/3` return typed errors for
  non-atom resources and non-map requirements (with a raised `qualify/2` demoting the provider
  to a rejected candidate); `CapabilityPack.load/1` refuses bare lists and non-string keys
  instead of raising; `Compiler` refuses empty-string step IRIs; `FOND.Counterexample` classifies
  malformed validator refusals.
- `PolicySwitch.sweep/4` clause grouping: argument validation moved ahead of the sweep so a
  bad `:modes`/`:horizon` opt is a typed refusal at `select/3`, not a crash inside the reduce.
- `PolicySwitch` exhaustion law: a sweep that exhausts at exactly the horizon returns the
  typed `{:error, {:horizon_exceeded, k, witness}}` shape from `FOND.PolicySupervisor.observe/3`
  (the supervisor may be born exhausted; the sweep surfaces the same shape) instead of a bare
  `:no_admitted_policy`.
- `ControlPlane.describe/1` typed refusals: non-atom (and nil) resources return
  `{:error, %{reason: :invalid_resource, resource: resource}}` instead of crashing inside the
  composed `StateMachine`/`Oban` surface assembly.
- DETS wedge fix (`Store.Dets`): sync-on-write-only (reads no longer pay a
  full-table `:dets.sync`), a 60s bounded-call timeout that converts a wedged
  server into a typed refusal instead of an `:infinity` hang, and signal
  lookups pushed down into DETS match specs (`sigs/2` map-pattern filter
  instead of O(total-signal) post-filtering). Kill-storm soak: 0 wedges across
  4 runs vs ~70 wedges/run on the pre-fix baseline
  (`lib/ash_pplan/reactor/durable/store/dets.ex`,
  `test/stress/checkpoint_burst_kill_test.exs`); the wedge regression court
  `test/hardening/dets_read_no_sync_test.exs` pins the 8-msg read AST set, the
  bounded-call contract, and write durability post-kill (11 tests).
- Repair-aware DETS reopen retry (`Store.Dets`): a kill mid-sync leaves the
  DETS header mid-repair, so an immediate reopen transiently fails; opens now
  retry with bounded backoff (`@repair_retries` x `@repair_backoff_ms` <=
  750ms, inside the burn-in's 10s reopen window) instead of surfacing the
  transient failure to the caller (`lib/ash_pplan/reactor/durable/store/dets.ex`,
  `test/hardening/dets_reopen_retry_test.exs`).
- Burn-in loop base-case fix (test-only): the witnessed "dets hang" was a missing cycle
  guard in the burn-in test loop, not a lib defect; the loop now bottoms out and the
  DETS burn-in runs 12/12 on the canonical build.
- Tokyo canonicalizer guards: JCS canonicalization raises a typed error on `Infinity`/
  `-Infinity` and refuses distinct-map-key collisions instead of emitting ambiguous JSON.
- OCEL export no longer crashes the whole export on attribute values with no `String.Chars`
  protocol (falls back to `inspect/1`).
- `StateMachine.describe_resource/1` no longer leaks wildcard actions into `wildcard_states`
  normalization, and refuses non-atom resources with a typed error instead of crashing.
- Workflow projection typed refusals: `Workflow.Model`, `Workflow.Project.HDDL`, and the
  Reactor projection return typed errors for malformed inputs instead of raising.
- Providers: `Providers.Qualify` and the registry return typed refusals for non-conforming
  providers/candidates; Oban activations refuse non-atom subjects with a typed error.
- Pack provenance (manufacture gate): the `ash-pplan-pack` and `ash-pplan-workflow-pack`
  root `ontology.ttl` entries were symlinks escaping the pack root, which ggen_igniter
  >= 26.10.1 refuses; both are now real files with `GENERATED-PROVENANCE` headers,
  matching the other packs' convention (`test/release_contract_test.exs` asserts
  provenance-stamped real files).
- `ExecutionReceipt.digest/1` clause order: the catch-all clause shadowed
  `{:halted, reactor}`, so halts were digested as `{:unknown, inspect(...)}` instead of
  over the halt state plus completed step results; the specific clause now precedes the
  catch-all and halts digest their actual substance.

### Changed

- The `generated/` folder is eliminated: ggen-manufactured modules are first-class at natural
  paths (`AshPPlan.Catalog.Projection`/`Catalog.Plan`, `Workflow.CapabilityCatalog`,
  `Providers.Index`, `Providers.*`, `Examples.*`); the manufacture pipeline is retargeted to
  those paths; the `AshPPlan.Generated` namespace is removed.
- TokyoDepeg is a test-only scenario: the corpus and courts live under `test/support/tokyo_depeg/`
  and `test/tokyo_depeg/`, outside the shippable `lib/` surface.

## 26.10.3 - 2026-10-03

### Added

- Standing ladder: `AshPPlan.Standing.Ladder` and the standing-pack law gates as inverted
  `verify/` companions (`verify/080_ladder_no_skipped_states.unbound.rq`,
  `verify/130_seal_once.unbound.rq`, `verify/140_parent_hash_closure.unbound.rq` -- zero rows is
  the pass condition, per ggen_igniter's gates/-vs-verify/ convention; the three
  violations-naming queries cannot pass under gates/' >= 1-row law) with per-pack `verify/`
  SPARQL gate + cardinality
  surfaces for all five ggen packs (workflow, standing, durable-chaos, durable-tla, store-conformance),
  wired into `bin/gate` and CI.
- ggen verification surface: `bin/ggen-verify`, `bin/ggen-replay-court` (fail-closed replay court
  wrapper), `bin/ggen-engine-report` (+ parse helper), `bin/ggen-doctor`; `ggen.toml` engine
  configuration.
- Diataxis documentation set under `docs/diataxis/` (how-to: run the ggen gates, adopt a
  marketplace pack; explanation: standing receipts and the ladder, process evidence and OCEL)
  plus `docs/diataxis/reference/public-api.md`.
- Chicago-school adoption: `AshPPlan.Test.Chicago` helpers (`sabotage_source!/3`,
  `assert_detected!/4`) and 5 sabotage courts pinning `Engine.wake/3` honesty,
  `Store.Dets` fail-closed/hard-kill/CAS behavior, and recipe-level regeneration detection.
- Release-prep receipts: calver policy audit, dependency-pin consistency, publish matrix and
  readiness audit, ex4pm triage (`receipts/*-2026-10-01.md`).

### Fixed

- Dependency modernization: `ash_ex4pm` moves from a pinned git ref to Hex (`>= 26.10.0`;
  resolves 26.10.2) and `ex4pm` moves to `~> 26.10` (resolves 26.10.1); the `ex4pm`
  `override: true` is gone — ash_ex4pm 26.10.x declares a compatible ex4pm requirement.
  Release-contract tests and ecosystem.lock.toml audit the hex floor instead of the git ref.
- ggen finding documented (ggen untouched): inline `VALUES` joins are silently
  vacuous under the pure-Elixir `sparql` engine (`GgenIgniter.Query.run/2`
  hardwires it), mis-scoped when joined to a BGP, and crash on
  `FILTER NOT EXISTS` + `VALUES` (witnessed 2026-10-02). The `verify/`
  companions added above are `VALUES`-free by construction.
- Manufacture repair: the mutation court is marker-based and self-healing (a killed run can no
  longer perpetuate a contaminated baseline; a script refusal over a hand edit is an admissible
  pass and a silent surviving hand edit is the only failure); the canonical-regeneration test is
  bounded at 15 minutes; per-court mutation targets are deterministic; run-unique scratch roots
  end cross-suite lock contention; template sort tiebreaks completed for byte-stable regeneration.

## 26.10.1 - 2026-10-01

### Added

- Semantic workflow framework: `AshPPlan.Workflow` (Spark DSL), canonical `Workflow.Model` with a content-addressed `Workflow.Subject` and explicit cross-projection correspondence, typed `AshPPlan.Capability`, one `AshPPlan.Provider` behaviour, `AshPPlan.Realization`, `Providers.Registry`/`Resolver` (qualify, seal a failed provider, typed refusal), and the lifecycle API `plan/resolve/run/resume/observe/inspect/explain/validate` (`AshPPlan.Workflow.Runtime`).
- Projections of one model: P-PLAN, HDDL (render/parse), FOND, Reactor; `AshPPlan.Reactor` identity/evidence middleware and dynamic-step inheritance.
- Generation-first: workflow pack `priv/ggen/ash-pplan-workflow-pack` (11 SPARQL gates, templates) generates the capability catalog, 16 providers, provider index, workflow models, HDDL files and 18 court tests from `ontology.ttl` via `bin/manufacture-workflow`. 36 capabilities, UltraCode and file_release reference workflows.
- Courts: same-subject (all four projections), regeneration, capability independence, provider failure, reactor fidelity, HDDL, FOND, dynamic inheritance, durability, evidence, authority, facade purity.
- Dependencies: reactor_req, reactor_file, reactor_process (vendored in `vendor/`, upstream pins `reactor == 1.0.6`); ash_oban 0.9.0.

- Native durable ledger engine `AshPPlan.Reactor.Durable.*`: `Engine` (start/attempt/signal/wake/cancel/runnable), `Run`, `Unwind`, `Checkpointed`, `Middleware`, `Verifier`, `Key`, `Status`, `Clock`, `Store` behaviour with `Store.Ets` (single node, non-persistent), `Testing` helpers. Design derived from mbuhot/magma (MIT per its mix.exs); see `docs/NOTICE.md`.
- `Durable.Store.Dets`: persistent single-node store (one DETS file, synced after every mutation); `Store.Ets` and `Store.Dets` share one generated conformance suite (`bin/manufacture-store-conformance`, pack `ash-pplan-store-conformance-pack`).
- Chaos, TLA+/TLC and status-conformance courts for the durable protocol, generated from the ontology (`bin/manufacture-durable-chaos`, `bin/manufacture-durable-tla`, `priv/tla/durable/**`).
- `Durable.PolicyDriver` (FOND policy consulted per observed outcome, admitted before use), `Durable.Counterfactual.replay/3` (scratch-store replay with one change), `Durable.Migration.plan/3` and `apply/4` (task correspondence for parked or pending runs).
- `AshPPlan.Standing`: PlanCorrect, ExecutionCorrect and ObservedConsequenceCorrect verdicts and a five-field receipt (`bin/manufacture-standing`).
- `docs/NOTICE.md`, README quickstart and limits, `bin/gate` and CI run every manufacture script and verify the generated directories are unchanged.
- Durable steps `Steps.Await`, `Steps.Poll`, `Steps.Dispatch`; `Workflow.Dispatch` capability family and durable adapter for event/state await and `Scheduling.Deferred`.
- Process-evidence rail: `AshPPlan.ProcessEvidence` (behaviour + `Event`) turns an `AshPPlan.ExecutionReceipt` and its subject into `task_attempted`/`task_succeeded`/`task_failed` events and exports pure OCEL 2.0 JSON (`objectTypes`/`eventTypes`/`objects`/`events`); the guarded `ProcessEvidence.AshEx4pm` adapter builds the `AshEx4pm` envelope and validates/ingests it through `Ex4pm.OCEL.validate_envelope/1`/`Ex4pm.Stream.Ingest.ingest_envelope/2` when the deps are loaded. `ex4pm`/`ash_ex4pm` are dev/test-only dependencies until published.

### Removed

- `AshPPlan.Continuation` and `capture_continuation`/`restore_continuation`/`resume_continuation`.
- `ash_durable_reactor` dependency.
- FOND runtime and supervision stubs; `policy_closure` stubs.
- Local `Durability.Checkpoint` and `Scheduling.Wakeup` adapters (superseded by the durable adapter).
- AshOban `Schedule` step.
- `capture_restore_resume` facade and legacy `Providers` modules.

### Changed

- Folds the unreleased 26.9.30 notes into this release.
- Source split: `lib/` holds only pplan machinery and generic vocabulary (App-Purity law); examples and fixtures live in `test/support`. Reactor names appear only under `lib/ash_pplan/reactor/**`.
- Delivery is at-least-once with idempotency keys; definition changes for in-flight runs go through `Durable.Migration`, there is no implicit versioning.
- Dependencies: `ex4pm` Hex 26.9.30 (override), `ash_ex4pm` pinned git, `stream_data`, `bb_reactor`, `bandit`, `plug`, optional `opentelemetry_api`; `ash_durable_reactor` removed; the only path dependency is in-repo `vendor/reactor_process` (dev/test).
- Release standing: CI has not been run for this version and the ecosystem digest is UNKNOWN.
- `TaskShape` requires an `ap:authorityCeiling`; ceilings above `construct` (`do`) remain inadmissible.

## 26.9.8 - 2026-09-28

### Security

- The `ash` requirement is now `~> 3.33 and >= 3.33.11`, excluding EEF-CVE-2026-93477 and EEF-CVE-2026-86338. The lock resolves patched `mint` (EEF-CVE-2026-82672) and `igniter` (EEF-CVE-2026-82584). `mix hex.audit` is a CI and release gate.
- `AshPPlan.Action.Run` accepts server-side `handlers:` and a `plans:` allowlist. With `handlers:` configured, a caller-supplied `:handlers` argument, which would let an API caller choose which step modules run, is refused.
- Continuations accept an optional `integrity_key:`: an HMAC-SHA256 over the envelope identity is verified in constant time before decoding. Unkeyed digests are documented as content addressing, not tamper resistance.
- The ETF codec re-applies its portability check on decode, so a forged payload carrying closures, pids, ports or references is refused.

### CI

- Eliminated: the serial `needs` chain (Elixir work no longer waits on a Docker pull), inline Python in the workflow (`bin/observe-ontology`), and drift between local and CI (`bin/gate` runs the same steps and reports what it could not run as `SKIP`).
- Reduced: cold builds (`deps` and `_build` cache keyed on the lock and toolchain), unbounded jobs (`timeout-minutes` everywhere), and mutable action tags (every third-party action pinned to a full commit SHA; checkout no longer persists credentials).
- Raised: the declared Elixir floor (1.17) is now tested, not assumed; `mix deps.get --check-locked` and `mix deps.unlock --check-unused` refuse a stale or unused lock; `version-type: strict` toolchains.
- Created: a single `release-gate` aggregate check (runs under `always()`, passes only if every job succeeded) to require in branch protection; a weekly scheduled run so live advisories surface off-PR; Dependabot for `mix` and `github-actions`; `workflow_dispatch`; and executable falsifiers in `release_contract_test.exs` for SHA pinning, job timeouts, read-only token, the aggregate gate, the Elixir floor, lock checks, the schedule and Dependabot coverage.

### Added

- `AshPPlan.FrontierEvidence.from_control_plane/3`: deterministic `frontier-evidence/v1` projection of already-resolved control-plane descriptors and FOND validation results into a content-addressed (`sha256:` `artifact_hash`) evidence envelope with a `CONSTRUCT` authority ceiling, for a downstream admission court; it refuses nothing and actuates nothing (merged in 7d9caad).
- FOND policy synthesis and TLA+ projection: strong/strong-cyclic `AshPPlan.synthesize_policy/3` with the `AshPPlan.FOND.Synthesis.solvable_states/2` winning region, render-only `AshPPlan.FOND.to_tla/4` (TLA+ module + TLC config), and the differential courts — pinned TLC 1.7.4 and a JVM-free TLA+-text reader — that must agree with `validate_policy/4` on the corpus (merged in 4e8a713).
- `AshPPlan.FOND.Synthesis`: strong and strong-cyclic policy synthesis (PR #7).
- Descriptor-first AshStateMachine and AshOban projections and `AshPPlan.ControlPlane` (PR #4).
- `AshPPlan.FOND.check/1`, and `:ignored_policy_states` in policy validation reports.
- AshStateMachine capabilities split into `supported` (upstream) and `configured` (this resource) facts.
- AshOban activations expose `active?`, `resolved_actor_persister` and `resolved_list_tenants`.
- `AshPPlan.Action.Run.Refusal` typed errors and the `allow_halt?:` option.

### Fixed

- Continuations could not capture any real halted compiled Reactor (its plan graph holds external funs and each step a `make_ref/0`), and resume failed with missing inputs. The compiler now binds deterministic step refs, the codec admits exported external funs, and resume passes the original inputs. Envelope schema is now version 2 with length-prefixed identity; version 1 envelopes are refused.
- `AshPPlan.Action.Run` returned `{:ok, _}` for failed Reactor outcomes, so Ash did not roll back. Failures now return `{:error, _}`, halts are refused unless admitted, and Reactor runs synchronously inside a transaction.
- StateMachine capabilities were hard-coded true; they are now derived from the resource's transitions, changes, policies and preparations.
- Paused/deleted AshOban triggers granted live capabilities; `stable_scheduler_identity?` was vacuously true without triggers; actor persistence and tenant fan-out ignored AshOban's runtime fallbacks; `{:snooze, period}` tuples and `:discard` results were classified as unknown.
- `construct_trigger/3` accepted foreign triggers and raised on non-Ash structs.
- `possible_next_states/2` confused an action named `:all` with "every action".
- FOND: non-list goals raised; hand-built domains with empty outcome lists were "solved"; policies keyed on states outside the domain were approved and entries the policy never follows were silently approved (they are now reported as `ignored_policy_states`); state-machine goals outside the lifecycle became phantom states; outcome normalization depended on the spelling of `1` vs `1.0`.
- FOND validation and synthesis were quadratic; a 4k-state chain drops from ~4.8s to ~20ms.
- `ExecutionReceipt.to_rdf/1` could emit multi-line triples from control characters in run identities.
- `execute/5`, `compile_spec/2` and `restore/3` raised on malformed input instead of returning typed refusals; non-keyword handler options were admitted.

## 26.9.7 - 2026-09-06

### Added

- ggen_igniter-manufactured P-PLAN plan catalog with step topology and variable flow.
- `AshPPlan.Compiler` projection from admitted semantic plans into `Reactor.Builder` graphs.
- Fail-closed compiler refusals for malformed plans, duplicate steps, dangling predecessors, missing/invalid handlers, cycles, and excessive terminal fan-out.
- Multi-terminal plan result collection without introducing another workflow runtime.
- PROV-style, content-addressed `AshPPlan.ExecutionReceipt` observations for succeeded, halted, and failed Reactor outcomes.
- Public `plans/0`, `plan/1`, `compile_plan/2`, and `execute/5` APIs.
- Independent ggen-ecosystem ontology qualification for the expanded semantic execution profile.
- Executable SHACL conformance gate (`./bin/conform`) over `ontology/shapes.ttl`, wired into CI.
- `./bin/conform-falsify`, which proves the conformance profile refuses thirteen real counterexamples rather than passing vacuously.
- SHACL coverage for P-PLAN plan/step/variable topology, projection order and source-term uniqueness, cross-plan predecessors and self-precedence.
- `AshPPlan.ReleaseReceipt` and `./bin/receipt`: content-addressed, compile-time evidence for an exact release head. This supplies the evidence the `observe` and `receipt` tasks in `planning/ash_pplan_v26_9_6.hddl` produce; the `released` predicate those tasks depend on still requires an actual publish, which this release does not perform.
- Package build gate (`mix hex.build`) on the exact release head.
- Executable falsifiers for every reachable compiler refusal reason, every receipt status, digest content-addressing, and multi-predecessor precedence. The three refusals that wrap `Reactor.Builder` failures remain defensive and unfalsified.
- `AshPPlan.predecessor_results/2`: a step can now read its P-PLAN predecessors' results, keyed by predecessor step IRI.
- `AshPPlan.ExecutionReceipt.to_rdf/1`: PROV-O N-Triples projection using the `ap:runIdentifier`, `ap:executionStatus` and `ap:resultDigest` properties the ontology already declared.
- `./bin/verify-package`, which compiles the built package from its own contents.
- `:too_many_predecessors` and `:reserved_context_keys` compiler refusals.

### Fixed

- `ontology/shapes.ttl` admitted only `reuse` and `gap`, so the ontology did not conform to its own profile once `extension` projections were added. The profile was never executed, so nothing detected it.
- The manufacture regeneration test wrote outside the authorized project root and was refused by `ggen_igniter`, failing CI.
- `AshPPlan.version/0` duplicated the version literal instead of deriving it from `mix.exs`.
- `mix check` had no CLI environment, so the release gate's central step refused in `:dev` and ran zero tests.
- `p-plan:isPrecededBy` was projected onto Reactor's `:_` convention, which Reactor drops before invoking the step, so precedence conveyed ordering but no result. Predecessor results are now bound to named, bounded arguments.
- `:run_id` was popped out of the Reactor run options, so Reactor minted an unrelated run identity and its telemetry described a different run than the receipt did.
- A failed outcome was digested over the error term, which embeds a `make_ref/0` reference and a stacktrace, so the same failure produced different digests on every run.
- Handler admission used `function_exported?/3` where Reactor uses a behaviour check, so the compiler could admit a handler `Reactor.Builder` then refused.
- A caller-supplied `:ash_pplan` context key silently replaced the compiler's step metadata, because Reactor merges the run context over the step context. It is now refused.
- `ecosystem.lock.toml` is a compile-time input of `AshPPlan.ReleaseReceipt` but was absent from the package `files:` list, so the published package would not compile.
- `ap:runIdentifier`, `ap:executionStatus` and `ap:resultDigest` were declared in the ontology and projected nowhere.

## 26.9.6 - 2026-09-06

### Added

- P-PLAN/PROV-O-first canonical ontology and SHACL profile.
- ggen_igniter pack that manufactures the projection catalog from the canonical ontology.
- Thin `AshPPlan` execution/convenience surface over existing Reactor semantics.
- Explicit mappings to Ash.Reactor, AshOban, and scheduling instead of a new workflow runtime.
- Explicit `PersistentContinuation` gap rather than an unsupported durability claim.
- HDDL project/SDL plan, architecture documentation, producer lock, and Chicago-style manufacture tests.
- CI gates using both the pinned ggen-ecosystem container and ggen_igniter regeneration.
