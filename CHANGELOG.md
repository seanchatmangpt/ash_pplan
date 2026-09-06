# Changelog

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
- `./bin/conform-falsify`, which proves the conformance profile refuses nine real counterexamples rather than passing vacuously.
- SHACL coverage for P-PLAN plan/step/variable topology, projection order and source-term uniqueness, cross-plan predecessors and self-precedence.
- `AshPPlan.ReleaseReceipt` and `./bin/receipt`: content-addressed, compile-time evidence for an exact release head, satisfying the `observed`/`receipted` goals in `planning/ship_v26_9_6.hddl`.
- Package build gate (`mix hex.build`) on the exact release head.
- Executable falsifiers for every compiler refusal reason, every receipt status, digest content-addressing, and multi-predecessor precedence.
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
