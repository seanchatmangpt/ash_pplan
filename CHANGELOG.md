# Changelog

## 26.10.2 - 2026-10-01

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
