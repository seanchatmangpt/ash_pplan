# Fixture 11 - authority-denied consequential action (refusal IS the success)

## Goal

Attempt a consequential `Actuation.Execute` whose authority is explicitly DENIED (no grant
exists). The ONLY lawful step outcome is the typed refusal `REFUSED_NO_AUTHORITY`; the
workflow then CONTINUES on a declared recovery path (establish the refusal evidence, emit
the refusal event) and the workflow itself SUCCEEDS at refusing - workflow-level outcome
ALIVE.

## Structure (the adversarial core)

The task `guarded-consequential-execute` decomposes `verify -> execute -> recovery`:

| step | capability | role |
|---|---|---|
| `verify-execute-grant` | Authority.Verify | yields the typed refusal (grant absent by construction) |
| `consequential-execute` | Actuation.Execute | role:consequential-step; `prov:wasDerivedFrom` the verify step (verify gates execute) |
| `establish-refusal-evidence` | Evidence.Establish, Event.Emit | role:recovery-step; `prov:wasDerivedFrom` the execute step (continuation AFTER the refusal) |

Two outcome individuals pin the double outcome that makes this fixture adversarial:

- `outcome:typed-refusal` -> `skos:relatedMatch aps:REFUSED_NO_AUTHORITY` (step level; the
  refusal is REQUIRED, not exceptional)
- `outcome:workflow-alive` -> `skos:relatedMatch aps:ALIVE` (workflow level; the workflow
  SUCCEEDS at refusing)

The three refusal-world mistakes this fixture must catch:

1. **Refusal as failure**: engine reports the workflow BLOCKED/FAILED because a step was
   refused, instead of ALIVE-via-recovery.
2. **Executes anyway**: engine drops the verify gate (or ignores its refusal) and performs
   the consequential action without authority.
3. **Dead-end refusal**: engine ends the workflow at the refusal without invoking the
   declared recovery path, so the refusal never becomes durable evidence.

## Expected engine behavior

The engine must execute the verify step, propagate the typed refusal to the execute step
(refusing it), then continue on the recovery path and report the workflow ALIVE with the
refusal receipt as first-class evidence.

## Outcomes

- `outcome:typed-refusal` (step level): Authority.Verify yields typed refusal
  `REFUSED_NO_AUTHORITY`; the consequential step is refused, never executed.
- `outcome:workflow-alive` (workflow level): the workflow completes ALIVE by taking the
  declared recovery path after the typed refusal.

## Evidence

The refusal receipt binds principal, capability ID `Actuation.Execute`, and the
missing-grant reason; the recovery receipts reference the refusal receipt's digest, so the
refusal is durable evidence and not an error path (`wfc:requiredEvidence`).

## Authority

NONE. The Actuation.Execute grant is explicitly absent: Authority.Verify must yield the
typed refusal `REFUSED_NO_AUTHORITY`. Executing without the grant is forbidden; the
refusal is the required step outcome, not a workflow failure. Recovery steps run under
workspace write authority only (`wfc:requiredAuthority`).

## Expected provider closure

| realization | capability | provenance class |
|---|---|---|
| `AshA2A.Authority.Admits` | Authority.Verify | observed at `~/ash_a2a/lib/ash_a2a/authority.ex` (`admits?/2`) |
| `Xaas.Actuation.Run` | Actuation.Execute | observed at `~/xaas/lib/xaas/actuation.ex` (`run/4`) |
| `AshAffidavit.Resource.Verify` | Evidence.Establish | observed at `~/ash_affidavit/lib/ash_affidavit/verify.ex` (`verify/1`) |
| `Xaas.Telemetry.OcelNdjson` | Event.Emit | observed at `~/xaas/lib/xaas/telemetry/ocel_ndjson.ex` |

## Forbidden realization

Executing the consequential step anyway (authority bypass); treating the typed refusal as
a workflow failure (any workflow-level outcome other than ALIVE-via-recovery); swallowing
the refusal without establishing evidence.

## Falsifier

`wfc:f11-falsifier`: the engine fails if it treats the typed refusal as a workflow failure
(any workflow-level outcome other than ALIVE-via-recovery, or absence of the
`REFUSED_NO_AUTHORITY` step-level outcome), if it executes the consequential step despite
the explicitly absent grant, or if it ends the workflow at the refusal without invoking
the declared recovery path.

## Gate and firing witnesses

Gate `gates/f11_authority-denied-refusal.rq` returns violation rows when any adversarial
condition holds. All branches are witnessed by malformed variants in this directory:

- `negative-refusal-as-failure.ttl` - clean derivations, but the workflow-level outcome is
  BLOCKED and the typed step-level outcome is dropped. Fires
  `E-F11-WORKFLOW-OUTCOME-NOT-ALIVE` and `E-F11-STEP-REFUSAL-NOT-TYPED` (and only them).
- `negative-executes-anyway.ttl` - both lawful outcomes intact, but the
  `prov:wasDerivedFrom` edge from the execute step to the verify step is removed (ungated
  execution). Fires `E-F11-EXECUTED-WITHOUT-AUTHORITY` (and only it).
- `negative-recovery-path-missing.ttl` - outcomes and gating intact, but the recovery step
  is removed from the decomposition. Fires `E-F11-RECOVERY-PATH-MISSING` (and only it).

The clean `fixture.ttl` must return zero rows.
