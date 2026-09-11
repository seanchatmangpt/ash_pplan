# Semantic execution

`ash_pplan` v26.9.7 compiles admitted P-PLAN topology into Reactor through Reactor's public `Reactor.Builder` API.

## Boundary

```text
ontology.ttl
  -> ggen_igniter SPARQL gates
  -> AshPPlan.Generated.PlanCatalog
  -> AshPPlan.Compiler
  -> Reactor.Builder
  -> Reactor.run
  -> AshPPlan.ExecutionReceipt
```

The compiler does not own scheduling, retries, compensation, undo, Ash actions, queues, or persistence. Those remain with Reactor, Ash.Reactor, AshOban/Oban, and application-owned Ash state.

## Behavior binding

A P-PLAN step describes process topology. Executable behavior is supplied explicitly as a map from semantic step IRI to a module implementing `Reactor.Step`, or to Reactor's `{module, options}` step form.

The compiler refuses before execution when a plan is malformed, contains duplicate steps, references a predecessor outside the plan, has a dependency cycle, lacks a handler, supplies an invalid handler, or exceeds the bounded multi-terminal collector surface.

## Precedence

`p-plan:isPrecededBy` becomes a Reactor result dependency. The dependency-only argument uses Reactor's existing `:_` convention, equivalent to the semantics Reactor's `wait_for` DSL desugars to. No second dependency scheduler exists in `ash_pplan`.

## Variables

`p-plan:hasInputVar` and `p-plan:hasOutputVar` are manufactured into step metadata and exposed in each step's Reactor context under `context.ash_pplan`. v26.9.7 intentionally passes the caller's input value as a single `:input` argument instead of dynamically creating atoms for arbitrary ontology variable IRIs.

## Receipts

`AshPPlan.execute/5` returns the observed Reactor outcome paired with an `AshPPlan.ExecutionReceipt`. The receipt records plan identity, run identity, succeeded/halted/failed status, wall-clock timestamps, monotonic duration, and a SHA-256 digest of the observed outcome.

A receipt is evidence, not authority. A halted receipt is not a persisted continuation. `PersistentContinuation` remains an explicit gap in the ontology until a concrete storage/wakeup/lease contract is admitted.
