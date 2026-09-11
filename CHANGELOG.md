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

## 26.9.6 - 2026-09-06

### Added

- P-PLAN/PROV-O-first canonical ontology and SHACL profile.
- ggen_igniter pack that manufactures the projection catalog from the canonical ontology.
- Thin `AshPPlan` execution/convenience surface over existing Reactor semantics.
- Explicit mappings to Ash.Reactor, AshOban, and scheduling instead of a new workflow runtime.
- Explicit `PersistentContinuation` gap rather than an unsupported durability claim.
- HDDL project/SDL plan, architecture documentation, producer lock, and Chicago-style manufacture tests.
- CI gates using both the pinned ggen-ecosystem container and ggen_igniter regeneration.
