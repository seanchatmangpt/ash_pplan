# Reference: ontology.ttl and the conformance shapes

Information-oriented reference for the semantic layer: `ontology.ttl` (canonical
graph), `ontology/shapes.ttl` (executable conformance profile), the auxiliary
vocabularies under `ontology/`, the SPARQL gates, the EEx templates, and the
projection flow into the manufactured modules under `lib/ash_pplan/catalog/`,
`lib/ash_pplan/workflow/`, and `lib/ash_pplan/providers/`. Nothing here supersedes
`AGENTS.md`; P-PLAN and PROV-O terms outrank Elixir names.

Observed this session: `priv/ggen/ash-pplan-pack/ontology.ttl` is a symlink
(`-> ../../../ontology.ttl`, checked with `ls -l`) and
`priv/ggen/ash-pplan-workflow-pack/ontology.ttl` is the same symlink. The other
four packs own local ontology files (see "Pack graph map").

## Source files

| file | role |
|---|---|
| `ontology.ttl` | Canonical graph. Sole semantic source (463 lines, `owl:versionInfo "26.10.1"`, `ontology.ttl:14`). |
| `ontology/shapes.ttl` | Admitted SHACL conformance profile for `ontology.ttl`. |
| `ontology/capability_pack.ttl` | SHACL shape mirroring `AshPPlan.CapabilityPack.validate/1`. |
| `ontology/fond_policy.ttl` | FOND capability/authority individuals (separate namespace; see gaps). |
| `ontology/fond_tla.ttl` | FOND/TLA differential-court vocabulary (classes, properties, individuals). |
| `ontology/fond_tla_shapes.ttl` | SHACL shapes for the FOND/TLA court vocabulary. |
| `ggen.toml` | ggen project config: `source = "ontology.ttl"`, `templates.dir = "priv/ggen/ash-pplan-pack/templates"` (`ggen.toml:4-8`). |
| `priv/ggen/ash-pplan-pack/` | Main pack: symlinked ontology, 3 SPARQL gates, 2 EEx templates. |
| `priv/ggen/ash-pplan-workflow-pack/` | Workflow pack: symlinked ontology, 11 SPARQL gates, 8 EEx templates. |

## Prefixes (`ontology.ttl:1-8`)

| prefix | IRI |
|---|---|
| `ap:` | `https://w3id.org/ash-pplan#` |
| `p-plan:` | `http://purl.org/net/p-plan#` |
| `prov:` | `http://www.w3.org/ns/prov#` |
| `dcterms:` | `http://purl.org/dc/terms/` |
| `owl:`, `rdf:`, `rdfs:`, `xsd:` | standard |

The ontology declares `owl:imports` of `p-plan` and `prov-o`
(`ontology.ttl:15`).

## Declared classes (`ap:` vocabulary)

20 `rdfs:Class` declarations. Subclass axioms anchor `ap:` terms to PROV-O.

| term | superclass | meaning (from `rdfs:comment`/`rdfs:label`) | ontology.ttl |
|---|---|---|---|
| `ap:Projection` | — | Runtime projection (catalog row). | 17 |
| `ap:BackgroundActivation` | `prov:Activity` | Background activation. | 20 |
| `ap:TemporalActivation` | `prov:Activity` | Temporal activation. | 24 |
| `ap:PersistentContinuation` | `prov:Entity` | Durable representation of halted process continuation state; storage stays application-owned. | 28 |
| `ap:ContinuationEnvelope` | `ap:PersistentContinuation` | Content-addressed halted-Reactor envelope; binds schema, plan/run identity, versions, codec, payload digest without granting resume authority. | 33 |
| `ap:SemanticExecution` | `prov:Activity` | Observed execution of an admitted P-PLAN plan projected into `Reactor.Builder`. | 38 |
| `ap:ExecutionReceipt` | `prov:Entity` | Content-addressed observation of one semantic plan execution outcome. | 43 |
| `ap:ReleaseObservation` | `prov:Activity` | Observed qualification of one exact release head (conformance, manufacture, generated-diff, test). | 48 |
| `ap:ReleaseReceipt` | `prov:Entity` | Content-addressed release evidence; evidence about a release, never authority to publish one. | 53 |
| `ap:FONDPolicy` | `prov:Plan` | Policy selecting an admitted action per reachable fully observable state under nondeterministic outcomes. | 61 |
| `ap:PolicyState` | `prov:Entity` | Policy state. | 66 |
| `ap:PolicyDecision` | `prov:Plan` | State-to-action selection belonging to a FOND policy. | 70 |
| `ap:ResourceLifecycle` | `prov:Entity` | Persistent application state; legal transitions owned by Ash actions and AshStateMachine. | 75 |
| `ap:PlannerObservation` | `prov:Entity` | Bounded observation (Reactor success/halt/failure) used to select the next policy action. | 80 |
| `ap:Capability` | — | Typed semantic requirement (`Family.Name`) a plan step targets; never an implementation. | 249 |
| `ap:Realization` | `prov:Entity` | Provider-qualified binding of a capability to a Reactor step; selection never alters workflow identity. | 253 |
| `ap:ExecutionProperty` | — | Property such as durable/resumable that a realization must support. | 258 |
| `ap:Correspondence` | — | Computed mapping of one workflow subject identity across P-PLAN, HDDL, FOND and Reactor projections. | 262 |
| `ap:CapabilityPack` | — | Named bundle of capability declarations; declaring grants no authority. | 266 |
| `ap:WorkflowSubject` | `prov:Entity` | Content-addressed workflow identity to which evidence is bound. | 270 |

## Declared properties

18 `rdf:Property` declarations.

Projection catalog columns (`ontology.ttl:85-91`): `ap:sourceTerm`,
`ap:targetRuntime`, `ap:targetPrimitive`, `ap:owner`, `ap:role`, `ap:status`,
`ap:order`.

Execution-receipt projection (projected by `AshPPlan.ExecutionReceipt.to_rdf/1`
onto an observed execution, `ontology.ttl:92`; all `xsd:string`, domain
`ap:ExecutionReceipt`): `ap:runIdentifier` (93), `ap:executionStatus` (98),
`ap:resultDigest` (103), `ap:workflowSubject` (275).

Workflow layer (`ontology.ttl:280-312`): `ap:requiresCapability` (domain
`p-plan:Step`, range `ap:Capability`), `ap:realizes` (`ap:Realization` →
`ap:Capability`), `ap:requiresProperty` (`p-plan:Step` → `ap:ExecutionProperty`),
`ap:correspondsTo` (domain `ap:Correspondence`), `ap:packId`
(`ap:CapabilityPack`, `xsd:string`), `ap:declaresCapability`
(`ap:CapabilityPack` → `ap:Capability`), `ap:authorityCeiling` (`xsd:string`;
comment: "Maximum authority a declaration may carry: observe, select or
construct. Never do.").

## Terms used but not declared in ontology.ttl

The workflow/provider individuals and `ontology/shapes.ttl` use additional
`ap:` terms that have no `rdfs:Class`/`rdf:Property` declaration line in the
canonical graph; they are defined by use plus SHACL constraint:

- Classes: `ap:Provider`, `ap:Workflow`, `ap:Task`, `ap:Method`.
- Properties: `ap:capabilityId`, `ap:family`, `ap:providerId`,
  `ap:providerModule`, `ap:cost`, `ap:supportsCapability`,
  `ap:supportsProperty`, `ap:emitsEvidence`, `ap:realization`, `ap:adapter`,
  `ap:operation`, `ap:stepOptions`, `ap:hasTask`, `ap:taskId`,
  `ap:workflowName`, `ap:goal`, `ap:dependsOn`, `ap:outcome`, `ap:hasMethod`,
  `ap:methodId`, `ap:decomposes`, `ap:subtask`.

## Projection individuals (`ap:Projection` catalog, `ontology.ttl:108-223`)

Looked up by `ap:sourceTerm` IRI, ordered by `ap:order`. Status vocabulary:
`reuse | gap | extension` (closed list, `ontology/shapes.ttl:35`). Current
distribution: 9 `reuse`, 4 `extension`, 0 `gap`.

| order | sourceTerm | targetRuntime | targetPrimitive | owner | role | status |
|---|---|---|---|---|---|---|
| 1 | `p-plan:Plan` | Reactor | Reactor definition or Reactor.Builder graph | reactor | plan | reuse |
| 2 | `p-plan:Step` | Ash.Reactor | Ash.Reactor step/action binding | ash | step | reuse |
| 3 | `p-plan:Variable` | Reactor | input/argument/result dependency | reactor | variable | reuse |
| 4 | `prov:Activity` | Reactor + Ash telemetry | observed execution activity | telemetry | activity | reuse |
| 5 | `prov:Entity` | Ash | resource/value state | ash | entity | reuse |
| 6 | `prov:Agent` | Ash | actor/authority context | ash | agent | reuse |
| 7 | `ap:BackgroundActivation` | AshPplan.Reactor.Durable | durable dispatch step | durable | background | reuse |
| 8 | `ap:TemporalActivation` | AshPplan.Reactor.Durable | durable poll/await step | durable | temporal | reuse |
| 9 | `ap:PersistentContinuation` | AshPplan.Reactor.Durable | durable ledger checkpoint store | durable | persistence | reuse |
| 10 | `ap:SemanticExecution` | AshPPlan.Compiler + Reactor.Builder | validated P-PLAN precedence graph compilation | ash_pplan | execution | extension |
| 11 | `ap:ExecutionReceipt` | AshPPlan.ExecutionReceipt | content-addressed PROV-style execution observation | ash_pplan | evidence | extension |
| 12 | `ap:ReleaseObservation` | CI release gate | exact-head qualification run | ash_pplan | observation | extension |
| 13 | `ap:ReleaseReceipt` | AshPPlan.ReleaseReceipt | content-addressed release evidence | ash_pplan | release-evidence | extension |

## Fixture plan (`ontology.ttl:226-245`)

`ap:SubscriptionRenewal a p-plan:Plan` with steps `ap:AuthorizePayment` and
`ap:RenewSubscription` (`isPrecededBy` `ap:AuthorizePayment`) and variables
`ap:Subscription`, `ap:PaymentAuthorization` (input/output wiring at
`ontology.ttl:242-245`). This is the technology-neutral worked plan projected
into `AshPPlan.Catalog.Plan`.

## Workflow individuals (shipped, `ontology.ttl:314-463`)

- 31 `ap:Capability` individuals `ap:cap_*` with `ap:capabilityId`
  (`Family.Name` pattern) and `ap:family`: domain x5, network x7 (incl.
  `Remote.Read`), filesystem x5, process x3, event x1, state x2, actuation x2,
  durability x1, scheduling x2, workflow x1, observation x1, agent x1.
- 11 `ap:Provider` individuals `ap:provider_*`, each with `ap:providerId`,
  `ap:providerModule` (`AshPPlan.Providers.*`), `ap:cost` (1–5),
  `ap:supportsCapability`, `ap:supportsProperty`, `ap:emitsEvidence`, and
  blank-node `ap:Realization` rows (`ap:realizes`, `ap:adapter`,
  `ap:operation`, `ap:stepOptions`): domain(1), network(3), remote(3), file(1),
  process(1), event_state(2), durability(2), scheduling(2), observation(1),
  a2a(5), durable_dispatch(2).
- Adapters used in shipped individuals: `ash_reactor`, `reactor_req`,
  `reactor_file`, `reactor_process`, `durable`, `local`. The shape's closed
  adapter list additionally admits `ultracode` (used by test examples),
  `bb_reactor`, `ash_durable_reactor`, `ash_oban`
  (`ontology/shapes.ttl:181`).
- The shipped ontology declares **no** `ap:Workflow` individuals;
  `bin/manufacture-workflow` documents that workflow/HDDL/court recipes run
  only over the merged example graph (`priv/ggen/ash-pplan-workflow-pack/bin/manufacture-workflow`,
  comment before its `sync court_provider` line). Example-namespace
  capabilities/providers/workflows live in
  `test/support/examples/ontology/examples.ttl` (296 lines, `ex:` prefix),
  merged by `bin/manufacture-examples` into `tmp/examples-ontology.ttl`.

## Conformance profile (`ontology/shapes.ttl`)

Executable: `./bin/conform` validates, `./bin/conform-falsify` proves refusal.
Not part of `mix check` (needs `rdflib` + `pyshacl`; `ontology/shapes.ttl:14-16`).

| shape | targets | constraints |
|---|---|---|
| `ap:ProjectionShape` | `ap:Projection` | exactly-one `ap:sourceTerm` (IRI), `ap:targetRuntime`, `ap:targetPrimitive`, `ap:owner`, `ap:role`, `ap:status`, `ap:order` (`xsd:integer`); `ap:status in ("reuse" "gap" "extension")` |
| `ap:ProjectionUniquenessShape` | `ap:Projection` | SPARQL: `ap:order` unique across projections; `ap:sourceTerm` unique across projections (non-deterministic/unreachable catalog otherwise) |
| `ap:PlanShape` | `p-plan:Plan` | exactly one `rdfs:label`; ≥1 step via inverse `p-plan:isStepOfPlan` (stepless plan would be dropped silently by the non-optional gate join) |
| `ap:StepShape` | `p-plan:Step` | exactly one `p-plan:isStepOfPlan` (class `p-plan:Plan`); `p-plan:isPrecededBy` values class `p-plan:Step`; ≤1 `rdfs:label`; `p-plan:hasInputVar`/`hasOutputVar` class `p-plan:Variable` |
| `ap:StepVariableShape` | `p-plan:Step` | SPARQL: every input/output variable's `p-plan:isVariableOfPlan` is the step's own plan |
| `ap:StepPrecedenceShape` | `p-plan:Step` | SPARQL: no predecessor outside the step's plan (dangling predecessor); no self-precedence (cycle) |
| `ap:VariableShape` | `p-plan:Variable` | exactly one `p-plan:isVariableOfPlan` (class `p-plan:Plan`) |
| `ap:CapabilityShape` | `ap:Capability` | exactly one `ap:capabilityId` (`xsd:string`, pattern `^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$`) and one `ap:family` |
| `ap:ProviderShape` | `ap:Provider` | exactly one `ap:providerId`, `ap:providerModule`, `ap:cost` (`xsd:integer`); ≥1 `ap:supportsCapability` (class `ap:Capability`); ≥1 `ap:realization` (node `ap:RealizationShape`) |
| `ap:RealizationShape` | `ap:Realization` | exactly one `ap:realizes` (class `ap:Capability`); one `ap:adapter` from the closed 10-value list; one `ap:operation`; one `ap:stepOptions` (`xsd:string`) |
| `ap:WorkflowShape` | `ap:Workflow` | exactly one `ap:workflowName`, one `ap:goal`; ≥1 `ap:hasTask` (class `ap:Task`) |
| `ap:TaskShape` | `ap:Task` | exactly one `ap:taskId`; one `ap:authorityCeiling` in `("none" "observe" "select" "plan" "construct")` — "may not exceed construct; do is never admissible" |

Triple floor: the profile is admitted only against a graph of ≥110 triples
(`MINIMUM_TRIPLES`, `bin/conform:29`), guarding against a silent near-empty
parse.

## Auxiliary vocabularies

### ontology/capability_pack.ttl

`ap:CapabilityPackShape` targets `ap:CapabilityPack`: exactly one
`ap:packId` (`xsd:string`); ≥1 `ap:declaresCapability` (IRI); at most one
`ap:authorityCeiling` in `("observe" "select" "construct")` — a pack may not
declare a ceiling above construct. Mirrors `AshPPlan.CapabilityPack.validate/1`.
Note the vocabulary difference from `ap:TaskShape`: the pack shape has no
`none`/`plan` values; the task shape has no `select`-only restriction debate —
each closed list is binding for its own shape.

### ontology/fond_policy.ttl

Four individuals under namespace `https://seanchatmangpt.github.io/ash_pplan/fond#`:
`fond:Policy` (a `fond:Capability`), `fond:ExactSubject`
(`fond:IdentityRequirement`), `fond:AuthorityNone` (`fond:AuthorityBoundary`),
`fond:TlaProjection` (`fond:DifferentialProjection`; `fond:authority`
`fond:AuthorityNone`). None of the `fond:Capability`/
`fond:IdentityRequirement`/`fond:AuthorityBoundary`/`fond:DifferentialProjection`
classes is defined in this repository.

### ontology/fond_tla.ttl

Vocabulary under `https://w3id.org/ash-pplan/fond#` and
`https://w3id.org/ash-pplan/tla#`: classes `fond:PolicySubject`,
`fond:Counterexample`, `fond:DifferentialVerdict`, `fond:ReplayBundle`,
`tla:RenderedPolicyModel`, `tla:RenderManifest`; properties `fond:subjectId`,
`fond:mode`, `fond:initialState`, `fond:hasCounterexample`,
`fond:counterexampleClass`, `fond:sourceCourt`, `fond:replayOf`,
`fond:semanticSeed`, `tla:moduleSha256`, `tla:cfgSha256`, `tla:subjectSha256`,
`tla:projectionAuthority`; individuals `tla:NoneAuthority` (`"NONE"`),
`fond:Strong` (`"strong"`), `fond:StrongCyclic` (`"strong_cyclic"`);
`fond:PolicySubject prov:wasDerivedFrom pplan:FONDPolicy` (here prefix
`pplan:` = `https://w3id.org/ash-pplan#`, i.e. `ap:FONDPolicy`).

### ontology/fond_tla_shapes.ttl

| shape | targets | constraints |
|---|---|---|
| `fond:PolicySubjectShape` | `fond:PolicySubject` | `fond:subjectId` matches `^sha256:[0-9a-f]{64}$`; `fond:mode` in `("strong" "strong_cyclic")`; one `fond:initialState` |
| `fond:CounterexampleShape` | `fond:Counterexample` | sha256 `fond:subjectId`; `fond:counterexampleClass` in `("liveness" "deadlock" "identity" "shape" "unknown")`; `fond:sourceCourt` in `("validator" "independent_checker")` |
| `tla:RenderManifestShape` | `tla:RenderManifest` | `tla:moduleSha256`/`tla:cfgSha256`/`tla:subjectSha256` each `^[0-9a-f]{64}$` |
| `tla:RenderedPolicyModelShape` | `tla:RenderedPolicyModel` | `tla:projectionAuthority` has value `"NONE"` exactly once |

## Gate pipeline: ontology → generated code

### 1. Conformance gate (before any generation)

- `bin/conform` (`bin/conform:1-93`): pyshacl `validate(data_graph,
  shacl_graph, advanced=True, inference="none")`; exit 0 iff `conforms` AND
  triple floor met. `--json` emits machine-readable evidence.
- `bin/conform-falsify` (`bin/conform-falsify:1-108`): appends 13 admitted
  counterexamples one at a time to the canonical graph and asserts each is
  refused: unadmitted projection standing; duplicate `ap:order`; duplicate
  `ap:sourceTerm`; predecessor from another plan; self-precedence; predecessor
  that is not a step; plan without label; plan with no steps; step with two
  labels; literal `ap:sourceTerm`; variable from another plan; step outside
  any plan; variable outside any plan.
- `bin/observe-ontology` (`bin/observe-ontology:1-26`): rdflib parse +
  triple count ≥110; run inside the pinned ggen-ecosystem container (release
  gate 3).
- `bin/conform` and `bin/conform-falsify` run in CI's conformance job, which
  the Elixir job depends on, so a refused projection never reaches
  ggen_igniter or the generated catalogs (`ontology/shapes.ttl:9-13`).

### 2. SPARQL gates (extraction, `priv/ggen/*/gates/*.rq`)

Main pack (`priv/ggen/ash-pplan-pack/gates/`), consumed by
`mix ggen_igniter.sync --pack-dir ... --engine oxigraph`:

| gate | binds | orders by |
|---|---|---|
| `010_projections.rq` | `?order ?source ?target ?primitive ?owner ?role ?status` from `ap:Projection` | `?order` |
| `020_plan_steps.rq` | `?plan ?planLabel ?step ?stepLabel ?predecessor` (labels and predecessor OPTIONAL) | `?plan ?step ?predecessor` |
| `030_plan_variables.rq` | `?plan ?step ?direction("input"/"output") ?variable` via UNION | `?plan ?step ?direction ?variable` |

Workflow pack (`priv/ggen/ash-pplan-workflow-pack/gates/`), 11 gates:
`010_capabilities` (`?id ?family`), `020_providers` (`?provider_id ?module
?cost`), `030_provider_caps`, `040_provider_props`, `050_provider_evidence`,
`060_workflows` (`?name ?goal`), `070_tasks` (task + capability + authority +
order), `080_task_deps` (`ap:dependsOn`), `090_task_outcomes`
(`ap:outcome`), `100_task_props`, `110_methods` (`ap:Method` /
`ap:decomposes` / `ap:subtask` / position).

Each pack also ships `verify/*.unbound.rq` inverted companions next to its
`gates/`: violations-naming queries where ZERO rows is the pass condition, with
per-gate contracts in `verify/cardinality.json`. The two families are
complementary, and the directory is the contract — `gates/*.rq` score
>= 1 row = pass; a violations query under `gates/` is doubly wrong (it scores
`:pass` exactly when the ontology is broken, and sync would flatten its
columns into template bindings). The law is ggen_igniter's
(`mix ggen_igniter.verify` moduledoc, "Why verify/ and not gates/"); the
standing pack's 080/130/140 companions were moved gates/ → verify/ under it
in v26.10.2. See
[How to run the ggen gates](../how-to/run-the-ggen-gates.md).

### 3. EEx templates → generated Elixir

| template | output | content |
|---|---|---|
| `ash-pplan-pack/templates/projection_catalog.ex.eex` | `lib/ash_pplan/catalog/projection_catalog.ex` | `AshPPlan.Catalog.Projection` — `@projections` rows (`source/target/primitive/owner/role/status`), `all/0`, `fetch/1` by source IRI, `by_role/1`; sorted by integer `ap:order`; normalizes raw N-Triples terms defensively at the projection boundary |
| `ash-pplan-pack/templates/plan_catalog.ex.eex` | `lib/ash_pplan/catalog/plan_catalog.ex` | `AshPPlan.Catalog.Plan` — plans grouped from `020`+`030` rows: `iri/label/steps[]`, per-step `predecessors/inputs/outputs` (sorted, deduped); `all/0`, `fetch/1` |
| `ash-pplan-workflow-pack/templates/capability_catalog.ex.eex` | `lib/ash_pplan/workflow/capability_catalog.ex` | capability rows |
| `ash-pplan-workflow-pack/templates/provider_index.ex.eex` | `lib/ash_pplan/providers/index.ex` | provider index |
| `ash-pplan-workflow-pack/templates/provider.ex.eex` | `lib/ash_pplan/providers/<provider_id>.ex` | one module per provider (`--for-each providers`); 11 files observed in the tree |
| `ash-pplan-workflow-pack/templates/workflow.ex.eex` | (examples only) `test/support/examples/workflows/<name>.ex` | shipped ontology has no workflows |
| `ash-pplan-workflow-pack/templates/hddl_file.hddl.eex` | (examples only) `planning/examples/<name>.hddl` | HDDL decomposition per workflow |
| `ash-pplan-workflow-pack/templates/court_workflow.exs.eex`, `court_provider.exs.eex` | courts: examples under `test/support/examples/courts/`; shipped provider courts under `test/courts/providers/` | anti-vacuity test generation |

Templates carry front matter (`to:`, `mode: file`) and a
`# GENERATED by ggen_igniter from ontology.ttl. Do not edit.` header in their
output.

### 4. Manufacture entry points

- `bin/manufacture` (`bin/manufacture:1-23`): two `mix ggen_igniter.sync`
  runs (oxigraph engine) for the two main-pack templates, `mix format` on the
  outputs, then delegates to
  `priv/ggen/ash-pplan-workflow-pack/bin/manufacture-workflow`.
- `bin/manufacture-workflow`: serial per-template syncs with
  `--on-stale prune`, reconciliation manifests under `tmp/mf-<name>`,
  outputs to `lib/ash_pplan/workflow/` +
  `test/courts/providers/`.
- `bin/manufacture-examples`: rdflib merge of `ontology.ttl` +
  `test/support/examples/ontology/examples.ttl` → `tmp/examples-ontology.ttl`,
  then workflow/provider/HDDL/court recipes over the merged graph into
  `test/support/examples/` and `planning/examples/`
  (`MIX_ENV=test`).
- `bin/gate` (`bin/gate:1-87`) runs the full local release sequence and treats
  `manufacture leaves generated source unchanged` (regenerate + `git diff
  --exit-code` over the generated dirs) as a gate step. See
  `docs/diataxis/reference/cli-and-release-gate.md` for the per-script
  reference; the release-gate order in `AGENTS.md` (Release gate) is:
  conform → conform-falsify → pinned container parse → hex.audit → format →
  compile → mix check → manufacture + generated-diff → verify-package →
  receipt.

## Pack graph map

| pack | ontology source | gates | templates |
|---|---|---|---|
| `ash-pplan-pack` | symlink → root `ontology.ttl` | 3 | 2 |
| `ash-pplan-workflow-pack` | symlink → root `ontology.ttl` | 11 | 8 |
| `ash-pplan-durable-chaos-pack` | local file `ontology.ttl` (2496 B) | 2 (`010_invariants`, `020_kill_phases`) | 2 (`.exs.eex`) |
| `ash-pplan-durable-tla-pack` | local file `ontology.ttl` (12083 B) | 5 (statuses, transitions, actions, guards, properties) | 4 (`.tla`, `.cfg`, `.rs`, `.exs`) |
| `ash-pplan-standing-pack` | local file `ontology.ttl` (3589 B) | 7 (fields, layers, standings, ceilings, chain, canon, phases) | 2 + `qualification-receipt.schema.json` |
| `ash-pplan-store-conformance-pack` | local file `ontology.ttl` (12863 B) | 3 (callbacks, laws, covers) | 1 |

The symlink law (`AGENTS.md`, Manufacture): `priv/ggen/ash-pplan-pack/ontology.ttl`
must remain a symlink to the root ontology; the ontology is never copied into
the pack. Observed 2026-10-01: the symlink is present for both packs that
consume the canonical graph; the four durable/standing/store packs carry their
own sub-ontologies and are outside that law's scope as written.

## Gaps and stale references observed

- `ap:status "gap"` is an admitted value in the profile
  (`ontology/shapes.ttl:35`) but no shipped `ap:Projection` currently carries
  it: `ap:projection-persistent-continuation` has `ap:status "reuse"`
  (`ontology.ttl:187`), while `AGENTS.md` (Durable store fence) still states
  "The ontology's `ap:projection-persistent-continuation` remains `gap`".
  One of the two is stale.
- `ap:Workflow`, `ap:Task`, `ap:Method` and 22 workflow/provider properties
  are constrained by shapes and consumed by gates but never declared in the
  canonical graph (no `rdfs:Class`/`rdf:Property` axioms), and the shipped
  graph contains no workflow/task individuals — the vocabulary is exercised
  only through the example graph.
- Two distinct FOND namespace IRIs coexist:
  `https://seanchatmangpt.github.io/ash_pplan/fond#`
  (`ontology/fond_policy.ttl:1`) vs `https://w3id.org/ash-pplan/fond#`
  (`ontology/fond_tla.ttl:2`, `ontology/fond_tla_shapes.ttl:2`). The classes
  used by `fond_policy.ttl` individuals are defined nowhere in the repo.
- `bb_reactor`, `ash_durable_reactor`, `ash_oban` are admitted adapter values
  (`ontology/shapes.ttl:181`) with no realization using them in the shipped
  ontology or the example graph observed.
