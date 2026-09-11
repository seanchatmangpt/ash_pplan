# Architecture

## Boundary

`ash_pplan` makes P-PLAN and PROV-O the conceptual interface. Ash/Reactor/Oban/Elixir are implementation details of one projection.

```text
public process semantics
        |
        v
 P-PLAN + PROV-O
        |
        v
   ontology.ttl
        |
        v
     ash_pplan
        |
 +------+------+----------------+
 |             |                |
 v             v                v
Reactor    Ash.Reactor       AshOban/cron
DAG        Ash effects       activation/time
```

## 80/20 reuse table

| Concern | Existing owner | ash_pplan action |
|---|---|---|
| dependency graph | Reactor | project |
| concurrency | Reactor | project |
| retry/backoff | Reactor | project |
| failed-step compensation | Reactor | project |
| undo of successful prior steps | Reactor | project |
| Ash actions/resources | Ash.Reactor | project |
| actor/tenant/policy | Ash | preserve |
| background jobs | AshOban/Oban | project |
| record-state triggers | AshOban | project |
| recurring schedule | AshOban/Oban cron | project |
| process provenance | Reactor/Ash telemetry -> PROV-O | project |
| durable halted continuation | no complete existing pattern | **gap** |

The last row is intentionally not papered over. A persisted Oban job is not automatically a persisted arbitrary Reactor continuation.

## Manufacture

The root `ontology.ttl` is the only editable semantic source. `priv/ggen/ash-pplan-pack/ontology.ttl` is a symlink to it. The pack's SPARQL gate selects admitted projections; its EEx template manufactures `AshPPlan.Generated.ProjectionCatalog` through `ggen_igniter`.

CI uses the exact ggen-ecosystem container digest recorded in `ecosystem.lock.toml` to parse the public ontology independently of the Elixir build. The Elixir job then regenerates and executes the projection.

## Extension law

A new runtime primitive is legal only when all are true:

1. the semantic concept cannot be represented faithfully with admitted public terms plus a thin ash_pplan extension;
2. existing Reactor/Ash.Reactor/AshOban/scheduler behavior is insufficient;
3. a concrete application reproduces the gap;
4. the proposed primitive has an executable falsifier;
5. the primitive does not steal authority from an existing owner.
