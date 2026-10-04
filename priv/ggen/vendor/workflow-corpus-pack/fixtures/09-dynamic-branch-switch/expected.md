# Fixture 09 - dynamic branch/switch (runtime dispatch, frozen identity)

## Goal

Route an inbound payload to exactly one of two processing arms selected at RUNTIME by an
observed routing value. The provider closure must cover BOTH arms before execution begins,
and the selected branch identity must be frozen at the pre-switch durability checkpoint so
a replay cannot flip it.

## Structure (the adversarial core)

The compound task `route-payload` is decomposed `observe -> checkpoint -> runtime-switch
(2 arms) -> converge-write`, plus the replay surface `resume-frozen-branch`:

| step | capability | role |
|---|---|---|
| `observe-routing-value` | State.Observe | emits `observed.route` |
| `checkpoint-pre-switch` | Durability.Checkpoint | freezes `observed.route` BEFORE dispatch |
| `runtime-switch` | - (role:branch-switch) | derives decision FROM THE CHECKPOINT |
| `arm-remote-fetch` | Http.Get | arm, guard `observed.route=="remote"` |
| `arm-local-read` | File.Read | arm, guard `observed.route=="local"` |
| `converge-write` | File.Write | consumes the executed arm's receipt |
| `resume-frozen-branch` | Durability.Resume | re-derives the SAME branch from the checkpoint receipt |

The branch target is not statically known: it is decided at runtime from `observed.route`.
Two invariants make this adversarial:

1. **Total-arm closure**: because the switch is dynamic, the engine must qualify BOTH arms'
   capabilities (`Http.Get`, `File.Read`) BEFORE execution - a closure covering only the
   observed arm at plan time is insufficient.
2. **Frozen branch identity**: the switch decision and the replay step both derive from the
   checkpoint, never from a live re-observation, so `Durability.Resume` replays the same
   branch identity deterministically.

## Expected engine behavior

The engine must admit the workflow only when the pre-execution closure covers both arm
capabilities, and must replay the checkpointed decision (not re-observe) after resume.

## Outcomes

- `outcome:routed` (success): exactly one arm executed per the observed routing value; both
  arms were closure-covered before execution; replay after checkpoint re-derives the same
  branch identity from the checkpoint receipt.

## Evidence

The switch decision is recorded at the pre-switch Durability.Checkpoint receipt; after
Durability.Resume the same branch identity is re-derived from that receipt, never from a
fresh State.Observe; the executed arm's receipt is bound into the converge receipt
(`wfc:requiredEvidence`).

## Authority

Session-local CONSTRUCT ceiling: observation and both read arms run under workspace read
authority; the converge write under workspace write authority. No publish or actuation
grant required; no ambient authority (`wfc:requiredAuthority`).

## Expected provider closure

| realization | capability | provenance class |
|---|---|---|
| `AshGraphlaw.Lifecycle.Run` | State.Observe | observed at `~/ash_graphlaw/lib/ash_graphlaw/lifecycle.ex` (`run/4`) |
| `AshAffidavit.Resource.Persist` | Durability.Checkpoint | observed at `~/ash_affidavit/lib/ash_affidavit/persist.ex` |
| `Reactor.Req.Get` | Http.Get | hex metadata only (no local inspection) |
| `Reactor.File.ReadFile` | File.Read | hex metadata only (no local inspection) |
| `Reactor.File.WriteFile` | File.Write | hex metadata only (no local inspection) |
| `AshAffidavit.Resource.Persist` | Durability.Resume | observed at `~/ash_affidavit/lib/ash_affidavit/persist.ex` |

## Forbidden realization

Executing an arm whose capability is absent from the pre-execution closure (arm first,
qualification later); re-observing after Durability.Resume to pick the branch (identity
flip across replay).

## Falsifier

`wfc:f09-falsifier`: the engine fails if it admits the workflow while any branch arm's
capability (`Http.Get` or `File.Read`) is uncovered by the pre-execution provider closure,
or if the branch decision is re-derived from a fresh `State.Observe` after
`Durability.Resume` instead of from the checkpointed receipt (branch identity flip across
replay), or if the switch decision is not derived from the pre-switch checkpoint at all.

## Gate and firing witnesses

Gate `gates/f09_dynamic-branch-switch.rq` returns violation rows when any adversarial
condition holds. All branches are witnessed by malformed variants in this directory:

- `negative-uncovered-arm.ttl` - full clean structure, but no closure member covers
  `File.Read`: arm-local is exposed. Fires branch `E-F09-UNCOVERED-ARM` (and only it).
- `negative-branch-flip-after-checkpoint.ttl` - full arm coverage, but the switch node AND
  the replay step derive their decision from the live `State.Observe` instead of the
  pre-switch checkpoint. Fires branches `E-F09-BRANCH-IDENTITY-UNFROZEN` and
  `E-F09-SWITCH-DERIVATION-UNPINNED` (and not the uncovered-arm branch - both arms are
  covered here).

The clean `fixture.ttl` must return zero rows.
