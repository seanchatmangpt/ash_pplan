# COMBINE Boundary Verdict: ash_pplan FOND vs ferroplan

**Date**: 2026-10-03. Verdict: **CONSUMER-OK** (no re-implementation of the ferroplan kernel;
one bounded parallel surface in policy validation, deliberately independent by design).

## Module surfaces compared

**ash_pplan** (`lib/ash_pplan/fond/`, ~1,500 LOC Elixir, pure/domain-local):
- `AshPPlan.FOND` (`lib/ash_pplan/fond.ex`, 416 LOC) — the closed domain primitive:
  `new/2`, `check/1`, and `validate_policy/4` (strong / strong_cyclic classification
  over the explicit finite transition map).
- `AshPPlan.FOND.Synthesis` — strong backward-attractor + strong-cyclic greatest-fixpoint
  synthesis (Cimatti et al. AIJ 2003 characterisations), explicit state space, typed
  `{:unsolvable, mode, witness_states}` refusals. **No counterpart exists in ferroplan** —
  grep over `ferroplan/crates/ferroplan/src/*.rs` shows no strong/strong-cyclic policy
  *synthesis* module; `invariants.rs:synthesize` is state-invariant synthesis, unrelated.
- `AshPPlan.FOND.Differential` — joins native validator with an *independent checker*
  (rendered TLA+/TLC via `FOND.to_tla/5`, `tla.ex`) — a court, not a planner.
- Surrounding runtime: `consumer.ex` (adapter dispatch of powerless intents),
  `provider_registry.ex` (capability/cost routing), `policy_supervisor.ex`,
  `policy_switch.ex`, `replay.ex`, `recovery.ex` — none of this exists in ferroplan.
- PDDL/HDDL artifacts (`planning/*.fond.pddl`, `*.hddl`) are *projections* of the
  workflow model (`workflow/project/hddl.ex`, `workflow/runtime.ex` `@kinds
  [:pplan, :hddl, :fond, :reactor]`), not kernel inputs at runtime; nothing in
  `mix.exs` or `lib/` references ferroplan.

**ferroplan** (`crates/ferroplan/src/policy_validation.rs`):
- `validate_fond_policy(PlanningProblem, UniversalPlan)` — reconstructs the selected-action
  graph over the universal planning IR, checks the declared transition relation,
  classifies Strong / StrongCyclic / Invalid, emits typed `PolicyIssue`s. Module doc is
  explicit: "The synthesizer and validator deliberately do not share fixpoint code" and
  "Validation never grants execution or actuation authority."
- Full generic kernel elsewhere (parser, grounder, search, sat, temporal, hddl crate) —
  none of it imported by ash_pplan; zero coupling in either direction (no dep, no NIF,
  no port, no CLI call).

## Overlap analysis

The only shared algorithm is FOND policy validation. It is *not* re-implementation across
the boundary: each validates over its own substrate — ash_pplan over its own explicit
`AshPPlan.FOND` domain map, ferroplan over its universal IR (`PlanningProblem`). The
independence is load-bearing: ash_pplan's `Differential` court needs a checker that does
not share the native fixpoint, and ferroplan's validator is exactly such an independent
implementation of the same obligations (Strong = bounded-step progress, StrongCyclic =
fairness-dependent goal reachability inside the policy). Same class of design as the
existing TLA+/TLC court.

## Boundary recommendation

- **Synthesis (strong/strong-cyclic fixpoints): ash_pplan owns it.** ferroplan has no
  synthesis counterpart and a closed explicit-domain synthesizer is cheap and domain-local;
  no move warranted.
- **Validation: keep both, keep them independent.** `AshPPlan.FOND.validate_policy/4`
  stays the native authority over the Elixir domain; ferroplan's `validate_fond_policy`
  stays the independent checker over the IR. If a wiring is later added (planning
  artifacts already render as `.fond.pddl`/`.hddl` projections), the composition is:
  ash_pplan renders the projection, ferroplan validates the rendered policy over the IR
  as a second-opinion court alongside TLC — never as the sole gate.
- **Replay: ash_pplan owns it.** Policy replay (`replay.ex`, `trace.ex`,
  `policy_supervisor`/`policy_switch`, durable Reactor store) is runtime/authority
  machinery ferroplan does not have; ferroplan produces evidence only
  ("manufactures evidence only" — its own doc).

## Falsifier for this verdict

Adding `ferroplan` as an ash_pplan dep, NIF, or port call would move the verdict toward
OVERLAP; likewise any move to delete `AshPPlan.FOND.validate_policy/4` in favor of
ferroplan's validator, or to port strong-cyclic synthesis into ferroplan, would re-open
the question.
