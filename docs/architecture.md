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
| semantic conformance | SHACL (`ontology/shapes.ttl`) | enforce |
| release observation | CI exact-head qualification | observe |
| release evidence | `AshPPlan.ReleaseReceipt` | receipt |
| durable halted continuation | no complete existing pattern | **gap** |

The last row is intentionally not papered over. A persisted Oban job is not automatically a persisted arbitrary Reactor continuation.

## Manufacture

The root `ontology.ttl` is the only editable semantic source. `priv/ggen/ash-pplan-pack/ontology.ttl` is a symlink to it. The pack holds three SPARQL gates and two EEx templates, and `ggen_igniter` manufactures two modules from them:

| Gate | Selects | Manufactures |
|---|---|---|
| `010_projections.rq` | admitted `ap:Projection` rows | `AshPPlan.Generated.ProjectionCatalog` |
| `020_plan_steps.rq` | plan/step topology and precedence | `AshPPlan.Generated.PlanCatalog` |
| `030_plan_variables.rq` | per-step input/output variables | `AshPPlan.Generated.PlanCatalog` |

CI uses the exact ggen-ecosystem container digest recorded in `ecosystem.lock.toml` to parse the public ontology independently of the Elixir build. The Elixir job then regenerates and executes the projection.

## Conformance

`ontology/shapes.ttl` is the admitted conformance profile for `ontology.ttl`, and it is executable rather than decorative:

```text
ontology.ttl
  -> bin/conform          (SHACL: does the canonical ontology conform?)
  -> bin/conform-falsify  (does the profile still refuse what it claims to?)
  -> ggen_igniter         (manufacture, only from an admitted ontology)
```

The profile refuses an unadmitted projection standing, a duplicate `ap:order` or `ap:sourceTerm`, a plan without a label, a step or variable outside any plan, a predecessor that is not a step, a predecessor in a different plan, and self-precedence. The last three are conditions `AshPPlan.Compiler` also refuses at compile time; refusing them at the semantic boundary means they never reach a manufactured catalog.

`bin/conform-falsify` exists because a conformance gate that cannot fail proves nothing. It reintroduces each counterexample against the real ontology and asserts the profile rejects it.

## Release observation and evidence

`planning/ship_v26_9_6.hddl` states three release goals — `released`, `observed` and `receipted` — and `planning/ash_pplan_v26_9_6.hddl` decomposes them through `verify`, `package`, `release`, `observe` and `receipt`. The release gate in `AGENTS.md` realizes `verify`, `package`, and the evidence that `observe` and `receipt` produce:

```text
exact head
  -> conform + falsify + container parse   (semantic qualification)
  -> mix check + manufacture + diff        (verified)
  -> mix hex.build                         (packaged)
  -> bin/receipt                           (release evidence)
```

`release` itself — a tag and a publish — has no realization in this repository. The gate runs on a `v*` tag so a tagged head is observed, but nothing here publishes, and `AGENTS.md` is explicit that a receipt grants no standing on its own.

`AshPPlan.ReleaseReceipt` digests the semantic source, the conformance profile, the producer lock and both manufactured catalogs at compile time, so the receipt describes the head that was actually built rather than whatever is on disk when it is read. It is evidence about a release, never authority to publish one.

## Extension law

A new runtime primitive is legal only when all are true:

1. the semantic concept cannot be represented faithfully with admitted public terms plus a thin ash_pplan extension;
2. existing Reactor/Ash.Reactor/AshOban/scheduler behavior is insufficient;
3. a concrete application reproduces the gap;
4. the proposed primitive has an executable falsifier;
5. the primitive does not steal authority from an existing owner.
