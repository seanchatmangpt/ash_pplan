# ash_pplan

**P-PLAN/PROV-O semantics projected into the existing Ash process stack.**

`ash_pplan` deliberately does not introduce another workflow runtime. The canonical object is a technology-neutral process model. The implementation is a projection onto capabilities that already exist:

| Public/process concept | Runtime projection |
|---|---|
| `p-plan:Plan` | Reactor definition / builder |
| `p-plan:Step` | Ash.Reactor step/action binding |
| `p-plan:Variable` | Reactor input/argument/result |
| `prov:Activity` | execution observation / telemetry |
| `prov:Entity` | Ash resource/value state |
| `prov:Agent` | Ash actor/authority context |
| background activation | AshOban trigger/worker |
| temporal activation | AshOban schedule / Oban cron |
| persistent continuation | explicit v26.9.6 gap; no invented runtime |

## v26.9.6 contract

1. `ontology.ttl` is the semantic source of truth.
2. `priv/ggen/ash-pplan-pack/ontology.ttl` is a git symlink to that source, so ggen_igniter cannot drift onto a second ontology.
3. `ggen_igniter` projects the ontology into `AshPPlan.Generated.ProjectionCatalog`.
4. `AshPPlan.run/4` is intentionally only a convenience call into Reactor; it owns no execution semantics.
5. Ash.Reactor, AshOban and scheduling retain their existing authority.
6. A new runtime primitive is admitted only after an observed gap proves those existing patterns insufficient.

## Manufacture

```bash
mix deps.get
./bin/manufacture
mix check
```

The generated catalog must remain unchanged after manufacture:

```bash
./bin/manufacture
git diff --exit-code -- lib/ash_pplan/generated/projection_catalog.ex
```

The repository pins its producer identities in `ecosystem.lock.toml`. CI separately validates the ontology inside the pinned `ggen-ecosystem` container and regenerates the Elixir projection with `ggen_igniter`.

## Architecture

```text
P-PLAN + PROV-O
      |
      v
  ontology.ttl
      |
      +--------------------------+
      |                          |
      v                          v
 ggen-ecosystem              ggen_igniter
 semantic court              manufacture
      |                          |
      +-------------+------------+
                    v
                ash_pplan
                    |
       +------------+-------------+
       |            |             |
       v            v             v
   Ash.Reactor    AshOban       scheduling
       |            |             |
       +------------+-------------+
                    v
              existing runtime
```

See `docs/architecture.md`, `docs/working-backwards-press-release-v26.9.6.md`, and `planning/ash_pplan_v26_9_6.hddl`.
