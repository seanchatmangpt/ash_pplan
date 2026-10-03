# SA2A adapter verdict — 2026-10-03

## Verdict: ADAPTER

`lib/ash_pplan/sa2a/` (6 modules, 199 LOC — task said 7, actual is 6; no 7th module exists on
disk) is a consumer adapter, not a fork of the ash_a2a kernel. It re-implements none of the
kernel logic ash_a2a owns: no replan loop, no attempt budget, no provider selection/exclusion,
no candidate envelope normalization, no consumer-side refusal codes, no router/decision
policy. It projects owner-side candidates into the shapes the kernel's `Provider` behaviour
expects and preserves subject identity across the boundary.

## Boundary contract (as witnessed in code)

- `AshA2A.Replan.Provider` (~/ash_a2a/lib/ash_a2a/replan/provider.ex) is the behaviour:
  `propose(map, keyword) -> {:ok, map} | {:error, term}` and `supports?(atom)`.
- `AshA2A.Replan.Port.AshPPlan` is the port; it delegates to `AshPPlan.SA2A.Provider` by
  default (`@owner_provider`), with a `legacy_propose/2` fallback that calls `AshPPlan`
  directly if the owner provider module is not loadable. Owner-first; adapter consumed via
  the kernel's port, not around it.
- The kernel owns: loop, AttemptBudget, ProviderSet selection/exclusion, ProviderResult
  normalization, SubjectLineage drift guard (`:replan_subject_drift`), ReplayKey, refusal
  vocabulary (`:replan_*` codes).

## Module-by-module evidence

| module | LOC | what it does | kernel logic re-implemented? |
|---|---|---|---|
| capability.ex | 24 | Static capability descriptor for :fond/:powl; `authority: :none, standing: :candidate`. No logic. | no |
| refusal.ex | 18 | Closed owner-side codes (`:missing_subject`, `:planner_refused`, ...) stamped `authority: :none`. Explicitly documented "Consumer-side consequence-kernel refusal codes are not owned here" (provider.ex moduledoc). Codes are input-validation, not `:replan_*` semantics. | no |
| subject_guard.ex | 21 | Owner-side subject fetch + exact-match preserve; emits `{:subject_drift, ...}` detail. Parallel to kernel's `SubjectLineage.guard/2` but owner-side pre-check, not a duplicate of the `:replan_subject_drift` vocabulary; kernel guard still runs in the loop (loop.ex calls `SubjectLineage.guard` on every attempt). | no (watch item below) |
| policy_candidate.ex | 64 | Calls `AshPPlan.select_policy/3` and `AshPPlan.plan/1` (the repo's admitted primitives), wraps result in a candidate map with `authority: :none, standing: :candidate`. | no |
| provider.ex | 30 | Pure dispatch on `:formalism` to PolicyCandidate; implements the `Provider`-behaviour-shaped surface the port consumes. | no |
| replay.ex | 42 | Delegates entirely to `AshPPlan.FOND.Replay` (the repo's existing deterministic replay, not ash_a2a's); binds fingerprint; stamps `authority: :none, standing: :candidate`. | no |

No `AshA2A` alias appears anywhere under `lib/ash_pplan/sa2a/` (grep of sa2a/*.ex for
`AshA2A`: only provider.ex references it, and only in its moduledoc). The only `AshA2A`
reference in ash_pplan/lib is that moduledoc line. Cross-repo coupling is one-directional:
ash_a2a → ash_pplan via the port.

Coupling direction: ash_a2a's port calls INTO the adapter; the adapter never calls ash_a2a.
So kernel evolution (loop, budget, refusal vocabulary) cannot be drifted against by
ash_pplan — drift is structurally impossible in the loop/budget/refusal axes. The only
 conceivable drift axes are candidate field shapes (contractual, kernel normalizes via
ProviderResult) and subject handling (see watch items).

## Watch items (not drift, recorded for the next review)

1. `SubjectGuard` vs `AshA2A.Replan.SubjectLineage`: two subject-drift checks exist
   (owner-side pre-check + kernel-side post-check). Redundant but not drift — the kernel
   guard always runs, so removing the owner-side check would not weaken the kernel. If
   the two ever disagree on what "same subject" means, the kernel wins (`:replan_subject_drift`).
2. Legacy path in `AshA2A.Replan.Port.AshPPlan.legacy_propose/2` (ash_a2a side, out of
   scope here) bypasses the adapter when the owner module is unloaded; it stamps
   `authority: :none, standing: :candidate` but produces a raw selection map, not the
   adapter's candidate shape. This is ash_a2a-side debt, not ash_pplan drift.
3. Task brief said "7 modules"; on-disk count is 6 under `lib/ash_pplan/sa2a/`.

## Re-point plan

None required. No module to delete, no call to re-route. The adapter is at the correct
altitude: owner-side candidate projection + subject preservation, kernel owns everything
else.

## Receipt

- Read (all, full): lib/ash_pplan/sa2a/{capability,policy_candidate,provider,refusal,replay,subject_guard}.ex
- Read (ash_a2a): lib/ash_a2a/replan/{provider,port/ash_pplan,refusal,proposal,subject_lineage,provider_result,router}.ex, replan/loop.ex (full)
- Grep evidence: `AshA2A` appears once in ash_pplan/lib (provider.ex moduledoc); no
  `AshPPlan.SA2A` re-implementation of loop/budget/refusal-vocabulary exists on either side.
- No code changed.
