# Fixture 05 - HDDL hierarchical decomposition

## Goal

Produce and publish a signed release artifact for `ash_pplan v26.9.30`: build the
artifact, sign it, publish it - by the pinned `direct-publish` method (three subtasks,
in that order).

## Method structure (the adversarial core)

The compound task `publish-signed-release` has TWO admissible HDDL methods over the
same subtask pool:

| method | ordered task set |
|---|---|
| `direct-publish` (PINNED) | build-artifact, sign-artifact, publish-artifact |
| `staged-publish` (legal but NOT pinned) | build-artifact, promote-staging, publish-artifact |

`wfc:expectedDecomposition` pins `wfc:f05-decomp-direct`: method `direct-publish`,
ordered RDF list `(build, sign, publish)`, declared `skos:note "arity:3"`.

## Expected engine behavior

The engine must select the pinned method and produce exactly its ordered task set.
Choosing `staged-publish` is choosing the wrong method even though it is a legal plan
for the same compound task.

## Outcomes

- `outcome:published` (success): signed artifact published; publication receipt
  references the signing receipt's digest.

## Evidence

Each subtask terminates with a completion receipt; the sign-artifact receipt binds the
digest of the artifact built by the build-artifact receipt
(`wfc:requiredEvidence`).

## Authority

Session-local CONSTRUCT ceiling; publish requires a named `Http.Post` grant referencing
the signed digest. No ambient publish authority (`wfc:requiredAuthority`).

## Expected provider closure

| realization | capability | provenance class |
|---|---|---|
| `Reactor.File.WriteFile` | File.Write | hex metadata only (no local inspection) |
| `AshAffidavit.Resource.Persist` + `AshAffidavit.Resource.Verify` | Evidence.Establish | observed at `~/ash_affidavit/lib/ash_affidavit/{persist,verify}.ex` |
| `Reactor.Req.Post` | Http.Post | hex metadata only (no local inspection) |

## Forbidden realization

Skipping `Evidence.Establish` and publishing an unsigned artifact (the staged-publish
sign-less fast path).

## Falsifier

`wfc:f05-falsifier`: the engine fails if it decomposes by `staged-publish` (wrong
method) or by any task set that drops build-artifact, sign-artifact, or publish-artifact
from the pinned ordering.

## Gate and firing witnesses

Gate `gates/f05_hddl_decomposition.rq` returns violation rows when either adversarial
condition holds. Both branches are witnessed by malformed variants in this directory:

- `negative-wrong-method.ttl` - fixture requires `method:direct-publish` but its
  expected decomposition is titled `method:staged-publish` (three subtasks, correct
  arity, wrong method). Fires branch `E-F05-WRONG-METHOD`.
- `negative-dropped-subtask.ttl` - correct method, but the pinned list is
  `(build, publish)`; `sign-artifact` is dropped. Fires branch
  `E-F05-DROPPED-SUBTASK` (one row per missing pinned subtask).

The clean `fixture.ttl` must return zero rows.
