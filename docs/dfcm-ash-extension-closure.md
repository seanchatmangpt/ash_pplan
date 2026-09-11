# DfCM Ash extension capability closure

This document records the capability review of the upstream `ash-project/ash_state_machine`
and `ash-project/ash_oban` implementations and the resulting ownership decisions in
`ash_pplan`.

The governing rule is **reuse before migration**. A capability is moved into `ash_pplan`
only when it is semantic/control-plane information that the owning runtime does not already
provide as a reusable execution primitive. Existing execution behavior is integrated by
introspection or delegation instead of copied.

## Closure model

```text
P-PLAN / PROV-O / HDDL / FOND
              |
              v
       ash_pplan control plane
              |
      +-------+--------+----------------+
      |                |                |
      v                v                v
     Ash        AshStateMachine      AshOban
 actions/state   lifecycle legality   activation/delivery
      |                |                |
      +----------------+----------------+
                       |
                       v
                    Reactor
                  saga execution
                       |
                       v
                     Oban
                durable job delivery
```

The ordering is semantic, not a call stack. Ash actions remain the preferred application DO
boundary. State-machine legality, Reactor execution and Oban delivery retain their respective
owners.

## AshStateMachine review

| Upstream capability | Owner | ash_pplan treatment |
|---|---|---|
| state attribute creation/validation | AshStateMachine transformer | project descriptor |
| initial states | AshStateMachine | project |
| default initial state inference | AshStateMachine | project |
| deprecated states | AshStateMachine | project; valid persisted states |
| wildcard state expansion | AshStateMachine | mirror exactly for planning |
| extra states | AshStateMachine | project |
| transition DSL | AshStateMachine | project to FOND relation |
| `action: :*` | AshStateMachine | expand to concrete update-action universe |
| update transition validation | AshStateMachine | do not duplicate |
| create initial-state validation | AshStateMachine | do not duplicate |
| upsert-create transitions | AshStateMachine | expose in action/transition metadata |
| atomic transition change | AshStateMachine | expose capability; do not duplicate |
| `next_state` change | AshStateMachine | expose capability; do not duplicate |
| possible-next-state helpers | AshStateMachine | delegate observation |
| pre-flight `ValidNextState` policy check | AshStateMachine/AshPolicy | expose owner/capability |
| ensure state selected | AshStateMachine transformer | expose capability |
| transition/default-state verifiers | AshStateMachine/Spark | rely on compile-time verifier |
| Mermaid state/flow diagrams | AshStateMachine.Charts | expose diagram capability |
| Clarity state-machine content | AshStateMachine/Clarity | leave with owner |
| Igniter installation | AshStateMachine/Igniter | developer tooling; do not migrate |

### Important wildcard invariant

AshStateMachine's manufactured wildcard state universe is not identical to the full set of
valid persisted states. Deprecated-only states remain legal values but are excluded from `:*`.
`AshPPlan.StateMachine` therefore carries both:

- `states` — every valid state, including deprecated states;
- `wildcard_states` — the exact wildcard universe manufactured by AshStateMachine.

This avoids either deleting historical lifecycle states from planning or accidentally allowing
new wildcard transitions into deprecated states.

## AshOban review

| Upstream capability | Owner | ash_pplan treatment |
|---|---|---|
| conditional record triggers | AshOban | project activation descriptor |
| scheduled generic/create actions | AshOban | project activation descriptor |
| scheduler cron / disabled scheduler | AshOban/Oban | project |
| active/paused/deleted cron state | AshOban + Oban Pro | project |
| query `where` eligibility | Ash/AshOban | project expression; do not re-evaluate |
| query sort | Ash/AshOban | project |
| read / worker-read actions | AshOban | project |
| keyset/offset/full-read streaming | AshOban | project |
| stream batch size / record limit | AshOban | project |
| scheduler/worker queues | AshOban/Oban | project |
| scheduler/worker priority | AshOban/Oban | project |
| explicit worker/scheduler module identity | AshOban | project |
| worker uniqueness / `trigger_once?` | AshOban/Oban | project |
| worker/scheduler max attempts | AshOban/Oban | project |
| custom/exponential backoff | AshOban/Oban | project |
| timeout | AshOban/Oban | project |
| worker opts and tags | AshOban/Oban | project |
| action input | AshOban | project |
| `read_metadata` | AshOban | project |
| `extra_args` | AshOban | project |
| actor persistence/default actor | AshOban | project authority metadata |
| tenant enumeration | AshOban | project declaration; never invoke while inspecting |
| tenant derived from record | AshOban/Ash multitenancy | project |
| shared context / job context | AshOban/Ash Scope | project |
| authorization | Ash/AshOban | preserve owner |
| transaction + `FOR UPDATE` locking | Ash/AshOban/DataLayer | project capability; do not duplicate |
| atomic update/destroy path | Ash/AshOban | project capability; do not duplicate |
| on-error action | AshOban/Ash | project |
| `on_error_fails_job?` | AshOban | project |
| final-attempt signaling | AshOban | project |
| trigger-no-longer-applies cancellation | AshOban | planner observation |
| `SnoozeJob` | AshOban/Oban | planner observation `:snoozed` |
| `CancelJob` | AshOban/Oban | planner observation `:cancelled` |
| chunk processing | AshOban + Oban Pro | project batch descriptor |
| automatic chunk actor/tenant partitioning | AshOban + Oban Pro | project |
| chunk bulk update/destroy | Ash/AshOban | project capability; do not duplicate |
| runtime `schedule` / `run_trigger(s)` | AshOban | DO; do not wrap as planner authority |
| `build_trigger` | AshOban | expose as CONSTRUCT-only delegate |
| Oban configuration/cron/queue wiring | AshOban | leave with owner |
| test queue draining | AshOban.Test/Oban.Testing | verification tooling; do not migrate |
| `assert_would_schedule` | AshOban.Test | evidence pattern, not runtime planner truth |
| Igniter trigger codemods | AshOban.Igniter | developer tooling; do not migrate |

## DfCM composition gains

`AshPPlan.ControlPlane.describe/1` now performs the combinatorial join that none of the
individual extensions is responsible for:

```text
Ash action
  x AshStateMachine transition membership
  x AshOban trigger membership
  x AshOban scheduled-action membership
  x FOND selectable action
  x Reactor execution outcome
  x continuation/replay contract
```

This makes combinations visible without granting them authority. For example, a planner can
observe that an action is both a legal lifecycle transition and asynchronously activated by a
record trigger, while the eventual invocation still passes through Ash policies and the
AshStateMachine/AshOban/Reactor boundaries.

## Planner observations

Reactor and Oban outcomes are normalized separately because they mean different things:

- Reactor: `:succeeded | :halted | :failed | :unknown`;
- AshOban/Oban: `:succeeded | :snoozed | :cancelled | :failed | :unknown`.

A snoozed delivery is not modeled as a failed domain transition. A cancelled job is not proof
that a domain goal is impossible. FOND policy may use these observations, but must explicitly
map them into its world-state model.

## Authority fence

`ash_pplan` does **not** migrate:

- state mutation from AshStateMachine;
- authorization or tenancy from Ash;
- scheduler/worker generation from AshOban;
- durable job storage, retry timing, queue concurrency or uniqueness from Oban;
- saga retry/compensation/undo/concurrency from Reactor;
- application-owned continuation storage.

The resulting system has more available combinations and less duplicated semantics at the same
time: the intended DfCM result.
