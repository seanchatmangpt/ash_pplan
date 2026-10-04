# Fixture 12 - same capability, two interchangeable qualified realizations
# (consequence-preserving substitution)

## Goal

Apply one domain change through the pinned capability `Domain.Action.Invoke`, which has
TWO qualified realizations (`AshReactor.Create` and `AshGraphlaw.Lifecycle.Run`) that are
INTERCHANGEABLE under a consequence-preserving substitution constraint: the closure must
admit EITHER, never an unqualified third realization, and the two must remain ONE
capability.

## Structure (the adversarial core)

The task `apply-domain-change` decomposes `invoke-domain-action -> bind-change-receipt`.
The substitution constraint is carried in three places:

- `dcterms:requires "substitution:consequence-preserving"` on the fixture;
- `skos:note "substitution:either-realization"` on the invoke step;
- BOTH qualified closures carry the IDENTICAL capability string `Domain.Action.Invoke`:
  one capability, two realizations.

| realization | capability | provenance class |
|---|---|---|
| `AshReactor.Create` | Domain.Action.Invoke | hex metadata only (`ash` package; no local inspection) |
| `AshGraphlaw.Lifecycle.Run` | Domain.Action.Invoke | observed at `~/ash_graphlaw/lib/ash_graphlaw/lifecycle.ex` (`run/4`) |
| `AshAffidavit.Resource.Verify` | Evidence.Establish | observed at `~/ash_affidavit/lib/ash_affidavit/verify.ex` (`verify/1`) |

The two substitution-world mistakes this fixture must catch:

1. **Unqualified third**: the closure set admits a realization of the pinned capability
   outside the qualified pair (e.g. `AshReactor.DirectSql`) - substitution without
   qualification.
2. **Identity split**: the two qualified realizations end up under DIFFERENT capability
   strings (e.g. `Domain.Action.Invoke` vs `Domain.Action.Invoke.v2`) - the engine has
   turned interchangeability into two capabilities, and the substitution contract is
   destroyed even though both realizations are individually "qualified".

## Expected engine behavior

The engine must select EITHER qualified realization for the invoke step, keep both
closures under the single pinned capability string, and refuse any third realization; the
consequence contract (identical change receipt) must survive the substitution.

## Outcomes

- `outcome:applied` (success): domain change applied through EITHER qualified realization;
  the change receipt carries the consequence digest and is identical in consequence across
  the pair; no unqualified realization was selected.

## Evidence

Whichever realization executes, the receipt records the realization identity and the
consequence digest; the substitution contract holds iff the consequence digest of either
realization is accepted as consequence-equal for the pinned capability - the receipt must
NOT name which realization was chosen as a functional requirement
(`wfc:requiredEvidence`).

## Authority

Session-local CONSTRUCT ceiling: Domain.Action.Invoke requires a named domain grant
binding the change record; substitution between the two qualified realizations never
widens authority - the same grant admits both or neither. No ambient authority
(`wfc:requiredAuthority`).

## Forbidden realization

`AshReactor.DirectSql` - an unqualified third realization of Domain.Action.Invoke outside
the qualified pair; and any naming that splits the pair into two distinct capabilities
(e.g. `Domain.Action.Invoke.v2`).

## Falsifier

`wfc:f12-falsifier`: the engine fails if it admits an unqualified third realization for
Domain.Action.Invoke (any realization outside the qualified pair), or if it treats the two
qualified realizations as different capabilities (capability identity split), or if a
substitution loses the consequence contract.

## Gate and firing witnesses

Gate `gates/f12_interchangeable-realizations.rq` returns violation rows when either
adversarial condition holds. Both branches are witnessed by malformed variants in this
directory:

- `negative-unqualified-third.ttl` - both qualified realizations intact under the one
  pinned capability, plus a THIRD closure realizing it with `AshReactor.DirectSql`. Fires
  branch `E-F12-UNQUALIFIED-THIRD` (and only it).
- `negative-identity-split.ttl` - exactly the two qualified realizations (no third), but
  the second closure's capability is renamed to `Domain.Action.Invoke.v2`. Fires branch
  `E-F12-IDENTITY-SPLIT` (and not the unqualified-third branch).

The clean `fixture.ttl` must return zero rows.
