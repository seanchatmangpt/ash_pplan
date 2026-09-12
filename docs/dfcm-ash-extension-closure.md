# DfCM Ash extension capability closure

This document records the capability review of upstream `ash-project/ash_state_machine` and `ash-project/ash_oban` and the resulting ownership/refactor decisions in `ash_pplan`.

Reviewed upstream subjects:

- AshStateMachine `13087b2682cbe84875d7a59dcf9bfa76f72d619d`
- AshOban `32e84ddcdcf1f565067a638f4f0b410c8a9396f4`

The governing rule is **reuse before migration**. A capability is moved into `ash_pplan` only when it is semantic/control-plane information that the owning runtime does not already provide as a reusable execution primitive. Existing behavior is integrated by public introspection or delegation instead of copied.

## Refactor invariants

The review produced five implementation laws:

1. **Public contract over reflection.** First-class dependencies are called through their public modules directly so API drift fails compilation. Dynamic `Module.concat/apply` is reserved for truly optional external surfaces such as Oban Pro identity metadata.
2. **One descriptor per extension/resource.** Each adapter resolves its upstream DSL once. The control plane joins those descriptors rather than re-introspecting the extension.
3. **Supported != configured != executed.** Extension capability, resource configuration and observed actuation are separate standings.
4. **CONSTRUCT != DO.** Building an Oban job changeset is allowed as construction; insertion, scheduling and execution remain with AshOban/Oban and the application authority boundary.
5. **No vacuous capability truth.** Empty configuration does not become a positive capability through defaults such as `Enum.all?([])`.

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
                    Reactor / Oban
                 owning runtimes
```

The ordering is semantic, not a call stack. Ash actions remain the preferred application DO boundary. State-machine legality, Reactor execution and Oban delivery retain their respective owners.

## AshStateMachine review

| Upstream capability | Owner | ash_pplan treatment |
|---|---|---|
| state attribute creation/validation | AshStateMachine transformer | describe |
| initial states | AshStateMachine | describe |
| default initial state inference | AshStateMachine | describe |
| deprecated states | AshStateMachine | describe; valid persisted states |
| wildcard state expansion | AshStateMachine | mirror exact manufactured universe |
| extra states | AshStateMachine | describe |
| transition DSL | AshStateMachine | project to FOND relation |
| `action: :*` | AshStateMachine | expand to concrete Ash update actions |
| update transition validation | AshStateMachine | do not duplicate |
| create initial-state validation | AshStateMachine | do not duplicate |
| upsert-create transitions | AshStateMachine | expose support/owner; do not duplicate |
| atomic transition change | AshStateMachine | expose support/owner; do not duplicate |
| `next_state` change | AshStateMachine | expose support/owner; do not duplicate |
| possible-next-state helpers | AshStateMachine | delegate observation |
| pre-flight `ValidNextState` policy check | AshStateMachine/AshPolicy | expose owner/capability |
| ensure state selected | AshStateMachine transformer | rely on owner |
| transition/default-state verifiers | AshStateMachine/Spark | rely on compile-time verifier |
| Mermaid state/flow diagrams | AshStateMachine.Charts | delegate directly |
| Clarity state-machine content | AshStateMachine/Clarity | leave with owner |
| Igniter installation | AshStateMachine/Igniter | developer tooling; do not migrate |
| exported formatter DSL | AshStateMachine | import into `.formatter.exs` |

### Compile-bound lifecycle adapter

Because `ash_state_machine ~> 0.2.13` is now a first-class dependency, `AshPPlan.StateMachine` directly references `AshStateMachine.Info`, `AshStateMachine`, `AshStateMachine.Checks.ValidNextState`, its public built-in changes and `AshStateMachine.Charts`. An incompatible upstream contract should fail the package build rather than silently becoming `UNKNOWN` through reflection.

### Wildcard invariant

AshStateMachine's wildcard state universe is not the full persisted-state universe:

```text
persisted states = wildcard states ∪ deprecated states
```

Deprecated-only states remain legal values but are excluded from `:*`. `AshPPlan.StateMachine` preserves both sets. `action: :*` is expanded only from the actual update actions exposed by `Ash.Resource.Info.actions/1`.

## AshOban review

| Upstream capability | Owner | ash_pplan treatment |
|---|---|---|
| conditional record triggers | AshOban | activation descriptor |
| scheduled generic/create actions | AshOban | activation descriptor |
| combined introspection | `AshOban.Info` | use as canonical descriptor input |
| scheduler cron / disabled scheduler | AshOban/Oban | describe exactly |
| active/paused/deleted cron state | AshOban + Oban Pro | describe |
| query `where` eligibility | Ash/AshOban | preserve expression; do not re-evaluate |
| sort/read/worker-read/stream configuration | Ash/AshOban | describe |
| scheduler/worker queues and priorities | AshOban/Oban | describe |
| explicit worker/scheduler module identity | AshOban | describe and test stability |
| worker uniqueness / `trigger_once?` | AshOban/Oban | describe |
| worker/scheduler max attempts | AshOban/Oban | derive configured retry capability |
| custom/exponential backoff and timeout | AshOban/Oban | describe |
| worker opts and tags | AshOban/Oban | describe |
| action input / metadata / extra args | AshOban | describe |
| actor persistence/default actor | AshOban | configured capability only when present |
| tenant enumeration/from-record | AshOban/Ash | configured capability only when present |
| shared context/job context | AshOban/Ash Scope | configured capability only when present |
| authorization | Ash/AshOban | preserve owner |
| transaction + locking | Ash/AshOban/DataLayer | describe; do not duplicate |
| on-error action/final-attempt behavior | AshOban/Ash | describe |
| snooze/cancel/no-longer-applies | AshOban/Oban | planner observations |
| chunk processing | AshOban + Oban Pro | configured descriptor; Pro availability separate |
| runtime `schedule` / `run_trigger(s)` | AshOban | DO; do not wrap as planner authority |
| `build_trigger` | AshOban | CONSTRUCT-only delegate |
| Oban configuration/cron/queue wiring | AshOban | leave with owner |
| test helpers | AshOban.Test/Oban.Testing | verification tooling; do not migrate |
| Igniter install/upgrade/module-name codemods | AshOban.Igniter | developer tooling; do not migrate |
| exported formatter DSL | AshOban | import into `.formatter.exs` |

### Configuration-derived capability law

`AshPPlan.Oban.describe_resource/1` first resolves the full trigger/schedule list using `AshOban.Info.oban_triggers_and_scheduled_actions/1`, then derives capability facts from that resolved list.

Examples:

```text
trigger exists                       => conditional_activation?
scheduled action exists              => temporal_activation?
trigger scheduler_cron != false      => temporal_activation?
max_attempts/max_scheduler_attempts > 1 => retry_delivery?
actor_persister configured           => actor_persistence?
default_actor configured             => default_actor?
list_tenants configured              => tenant_fanout?
use_tenant_from_record?              => tenant_from_record?
shared_context configured            => shared_context?
chunks configured                    => chunk_processing?
AshOban.Info.pro?                    => chunk_processing_available?
```

The last two are intentionally different: package/runtime support does not claim that the resource configured chunking.

## DfCM composition gains

`AshPPlan.ControlPlane.describe/1` performs the combinatorial join none of the individual extensions owns:

```text
Ash action
  × AshStateMachine transition membership
  × AshOban trigger membership
  × AshOban temporal membership
  × FOND selectable action surface
  × Reactor execution outcome surface
  × continuation/replay contract
```

Each extension is resolved once. The control plane consumes its descriptor and only derives cross-extension relationships. It does not independently inspect the same DSL again.

For example, a planner can observe that one action is both a legal lifecycle transition and asynchronously activated by a record trigger. Invocation still passes through Ash policy/action authority and the owning AshStateMachine/AshOban/Reactor boundaries.

## Planner observations

Reactor and Oban outcomes remain distinct:

- Reactor: `:succeeded | :halted | :failed | :unknown`;
- AshOban/Oban: `:succeeded | :snoozed | :cancelled | :failed | :unknown`.

A snoozed delivery is not a failed domain transition. A cancelled job is not proof a domain goal is impossible. FOND may consume these observations only through an explicit downstream world-state mapping.

## Authority fence

`ash_pplan` does **not** migrate:

- state mutation or transition legality from AshStateMachine;
- authorization, resource state or tenancy from Ash;
- scheduler/worker generation from AshOban;
- durable job storage, retry timing, queue concurrency or uniqueness from Oban;
- saga retry/compensation/undo/concurrency from Reactor;
- application-owned continuation storage.

The DfCM result is therefore increased combinatorial visibility with reduced duplicate semantics:

```text
max(capability composition) subject to zero duplicated runtime authority
```
