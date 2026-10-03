# SA2A Adapter Verdict — 2026-10-03

**Verdict: ADAPTER** (not a drifted fork; no re-point plan required)

## Scope compared

- `/Users/sac/ash_pplan/lib/ash_pplan/sa2a/` (6 modules, 199 lines total)
- `/Users/sac/ash_a2a/lib/ash_a2a/replan/` (provider/port/replay/refusal surfaces)

## Module-by-module evidence

| ash_pplan module | ash_a2a counterpart | Relationship |
|---|---|---|
| `AshPPlan.SA2A.Provider` | `AshA2A.Replan.Provider` (behaviour) / `AshA2A.Replan.Port.AshPPlan` | Implements the `propose/2` + `supports?/1` callbacks duck-typed (no compile-time dep, so no `@behaviour`); consumer adapter `AshA2A.Replan.Port.AshPPlan` explicitly delegates to `AshPPlan.SA2A.Provider` as its `@owner_provider` (port/ash_pplan.ex `owner_provider?/1` detection + `owner.propose/2` delegation) |
| `AshPPlan.SA2A.Refusal` | `AshA2A.Replan.Refusal` | Disjoint code vocabularies by design: owner codes (`missing_subject`, `missing_domain`, `missing_initial`, `missing_plan_iri`, `plan_not_found`, `unsupported_formalism`, `planner_refused`) vs consumer codes (`replan_subject_drift`, `replan_provider_unavailable`, …). Same `%{code, detail, authority: :none}` shape. `port/ash_pplan.ex` moduledoc: "Consumer-side consequence-kernel refusal codes are not owned here." |
| `AshPPlan.SA2A.Replay` | `AshA2A.Replan.ReplayKey` | Not a fork: ash_pplan's `Replay` delegates to the repo's own `AshPPlan.FOND.Replay.build/5` + `bind_fingerprint/1` (existing deterministic replay), merely binding caller subject + fingerprint for the SA2A caller. Consumer side keys attempts via `ReplayKey.build/3` SHA-256. Complementary, zero duplicated logic. |
| `AshPPlan.SA2A.PolicyCandidate` | `AshA2A.Replan.Proposal` family | Owner-side manufacture over `AshPPlan.select_policy/3` and `AshPPlan.plan/1` — the planner's own admitted primitives, not re-implementations of ash_a2a logic. |
| `AshPPlan.SA2A.SubjectGuard` | `AshA2A.Replan.SubjectLineage` (related concern) | Owner-side exact-subject preservation (`preserve/2` refuses `{:subject_drift, expected, actual}`); complements rather than duplicates consumer-side lineage. |
| `AshPPlan.SA2A.Capability` | — | Owner-local descriptor table (`[:fond, :powl]`, `authority: :none`), no ash_a2a analog needed. |

## Why not a drifted fork

1. **Dependency direction is correct**: `ash_pplan` has no `ash_a2a` dep (mix.exs); `ash_a2a` owns `replan/port/ash_pplan.ex` which delegates to the owner-side provider. This is the documented "owner-adapter-first port" (MERGE NOTE in `AshA2A.Replan.Port.AshPPlan`).
2. **Zero re-implemented kernel logic**: the 199 lines are guard/refusal/shape code over `AshPPlan.select_policy/3`, `AshPPlan.plan/1`, and `AshPPlan.FOND.Replay` — no planner or replan kernel logic copied from `ash_a2a/replan`.
3. **Contract alignment**: `propose/2` returns `{:ok, candidate}` / `{:error, %{code, detail, authority: :none}}` exactly as the consumer adapter expects; `authority: :none` + `standing: :candidate` invariant held in every success shape across all six modules.
`authority: :none` / `standing: :candidate` invariant holds in every success shape across all six modules.

## No re-point plan required

`lib/ash_pplan/sa2a/` is the owner-side thin waist of the COMBINE boundary. No drift,
no fork, no re-point action items. Only watch item: the `supports?/1` match between
`AshPPlan.SA2A.Capability.supported/0` (`[:fond, :powl]`) and
`AshA2A.Replan.Port.AshPPlan.supports?/1` (hardcoded `[:fond, :powl]`) is duplicated
on the consumer side; if the owner adds a formalism, the consumer adapter's hardcoded
list must move to owner capability discovery or it will silently narrow the surface.
