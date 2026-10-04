# ECO-SAGA-COMPENSATE — Upstream PR (ggen-marketplace)

Local branch prepared for upstream; **not pushed**.

## Branch

- Repo: `/Users/sac/ggen-marketplace` (restored to `main` @ `503af6c2` after the work; the work lives on the branch)
- Branch: `eco-saga-compensate-upstream` @ `65e4114be`
- Base: `main` @ `503af6c27cef7838dcd82755ab2fe6a44f9eb6a2` (exactly the sha `priv/ggen/vendor/sync.sh` pins as `rt_expected_sha`)
- One commit, one file: `packs/ash-runtime-integration-contract-pack/ontology.ttl` (+15 lines)

## Diff summary

The working-tree saga block (uncommitted REACTOR-SAGA lane addition, +31 lines) carried the
`rt:SagaCompensation` vocabulary **and** two consumer-specific individuals. The branch commit keeps
the vocabulary, removes the individuals:

- **Removed** (now consumer-overlay-only):
  - `rt:saga-comp-dispatch` → `AshPPlan.Reactor.Durable.Compensations.Dispatch`,
    step `AshPPlan.Reactor.Durable.Steps.Dispatch`, `rt:undoPrefix "ash_pplan.undo.dispatch"`, `rt:seqOrder 1`
  - `rt:saga-comp-poll` → `AshPPlan.Reactor.Durable.Compensations.Poll`,
    step `AshPPlan.Reactor.Durable.Steps.Poll`, `rt:undoPrefix "ash_pplan.undo.poll"`, `rt:seqOrder 2`
- **Kept in the pack** (generic vocabulary the overlay binds against): `rt:SagaCompensation a rdfs:Class`
  (`rdfs:subClassOf prov:Entity`) and the six properties `rt:seqOrder`, `rt:compensationModule`,
  `rt:stepModule`, `rt:stepLabel`, `rt:undoPrefix`, `rt:effect`.

## Fixtures

`tests/positive.ttl` and `tests/cross-contract-positive.ttl` contain no rows referencing the removed
individuals (their `rt:compensationModule` rows are the generic `Example.Runtime.*` Integration
witness) — no fixture migration required; verified by grep over the whole pack.

## Validation (real output, rdflib 7.6.0)

- `ontology.ttl` parses: 160 triples.
- All 4 gates (`01-core-vocabulary`, `02-runtime-shape-vocabulary`, `03-provenance-root`,
  `04-saga-compensation-gate`) → 0 violation rows against the ontology alone and against
  `ontology + tests/positive.ttl` and `ontology + tests/cross-contract-positive.ttl`.
- `queries/140-saga-compensation.rq` → 0 rows (individuals correctly gone from the pack; the query
  itself stays and drives from the consumer overlay's individuals).
- Pack remains self-validating; gate 04 is a rows=violations gate, so zero individuals = pass.

## Consumer contract (where the semantics moved)

`/Users/sac/ash_pplan/priv/ggen/ash-pplan-runtime-overlay/ontology.ttl` already carries the moved
individuals (`rt:saga-comp-dispatch`, `rt:saga-comp-poll`) bound against the pack vocabulary, plus
the consumer `rt:Integration` row. Contract:
`AshPPlan.Reactor.Durable.Compensations.{Dispatch,Poll}`, `undoPrefix ash_pplan.undo.*`
(`ash_pplan.undo.dispatch`, `ash_pplan.undo.poll`).

## What the consumer must re-sync after the upstream merge

The vendored copy of the runtime-integration pack under
`/Users/sac/ash_pplan/priv/ggen/vendor/ash-runtime-integration-contract-pack/` still carries the
saga residue (it was vendored from the working tree with the individuals present). After the
upstream merge lands on `main`:

1. Re-pin `rt_expected_sha` in `priv/ggen/vendor/sync.sh` to the new marketplace `main` sha
   (the pin gate refuses loudly on HEAD move — set `RTI_ALLOW_MOVED_MARKETPLACE=1` only to bridge).
2. Re-run the vendor sync and lock check:

   ```
   bin/... (from /Users/sac/ash_pplan)
   priv/ggen/vendor/sync.sh ~/ggen-marketplace
   priv/ggen/vendor/verify_lock.sh
   ```

3. Regenerate the runtime-contract surfaces from the re-pinned bytes:
   `bin/manufacture-runtime-contract` (from `/Users/sac/ash_pplan`).
4. Run the runtime-contract courts: `bin/runtime-contract-courts`.

## Restore state witnessed

After the branch commit, `/Users/sac/ggen-marketplace` was restored to `main` @ `503af6c2` with the
original uncommitted state intact: the saga block (+31 lines) still present in
`packs/ash-runtime-integration-contract-pack/ontology.ttl`, and the other lanes' files
(`lifecycle.toml`, `ash-extension-core-pack`, `gcp-marketplace-saas-pack`, untracked templates) untouched.
