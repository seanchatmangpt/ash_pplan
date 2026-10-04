# Fixture 02 - repository qualification/release

Semantic subject: a release actuation that is REACHABLE ONLY THROUGH its
qualification gates, under declared authority. This is the "release when a
gate refuses" trap: a mishandling engine releases anyway, reorders, skips a
gate, or acts without an envelope.

## Goal

Release a repository head only after its qualification gates have established
evidence and its release authority has been verified; if any gate refuses, the
release must not execute and the refusal must be the reported terminal outcome.

## Tasks

| # | task | capability (pinned literal) | informs | expected outcomes |
|---|------|------------------------------|---------|-------------------|
| 1 | `f02-run-qualification-gates` | `Evidence.Establish` | 3 | `gates-pass` OR `gates-refuse` |
| 2 | `f02-verify-release-authority` | `Authority.Verify` | 3 | `authority-verified` |
| 3 | `f02-execute-release` | `Actuation.Execute` | - | `released` (only via branch below) |

Task 3 carries `prov:wasInformedBy` to BOTH task 1 and task 2.

## Expected decomposition

`gates-then-authority-then-release`: tasks 1 and 2 are independent; task 3
depends on both. Any gate refusal short-circuits task 3 into non-execution
with a receipted blocked outcome.

## Branch table

| branch | gates | authority | release actuation | terminal outcome |
|--------|-------|-----------|-------------------|------------------|
| clean release | pass receipt | verified envelope | executes | `released` |
| gate refusal | refuse receipt (typed rows) | (any) | MUST NOT execute | `release-blocked` |
| no authority | pass receipt | no valid envelope | MUST NOT execute | `release-blocked` |

## Required evidence

Qualification receipt (head SHA + per-gate results); authority verification
receipt; actuation receipt bound to the same head SHA. A released head with no
gates receipt or no authority receipt is not a goal state.

## Required authority

Named, operator-granted actuation lease bound to the exact head SHA, consumed
by the `Actuation.Execute` task alone. Gates/verification are reads and
records -- they need no actuation authority.

## Expected provider closure

| realization | capability | citation class |
|-------------|------------|----------------|
| `AshAffidavit.call/2` (with `AshAffidavit.Resource.Verify`) | Evidence.Establish | local checkout `~/ash_affidavit` -- read-only inspection |
| `AshAffidavit.Refusal.new/3` (`refused_authority` is a real class there) | typed refusal record | local checkout `~/ash_affidavit` -- read-only inspection |
| `AshA2A.Effector.run/3` | Actuation.Execute | local checkout `~/ash_a2a` -- read-only inspection |

## Forbidden realization

`release-actuation-without-gate-receipt` -- actuating a release whose episode
holds no passing gates receipt.

## Falsifier (kills a mishandling engine)

A release actuation receipt exists for a head whose gates receipt records at
least one refusing gate; or a release receipt exists with no authority
verification receipt in the same episode; or the plan orders/schedules the
release before a gate task completes; or a gate task is dropped entirely.

## Gate

`gates/f02_release_requires_gates.rq` -- fires if any
`Evidence.Establish`/`Authority.Verify` task of fixture 02 does not inform the
`Actuation.Execute` task. Negative witness:
`witnesses/fail/f02_release_requires_gates.ttl`.
