# OCEL Vocabulary Audit — COMBINE Map Item (2026-10-03)

Scope: `/Users/sac/ash_pplan`, `/Users/sac/xaas`, `/Users/sac/beam4pm`, `/Users/sac/wasm4pm` (read-only). Confirms COMBINE map item: OCEL emission exists in all 4 repos, in 4 divergent vocabularies.

## Comparison Table

| Dimension | ash_pplan | xaas | beam4pm | wasm4pm |
|---|---|---|---|---|
| Canonical emission point | `lib/ash_pplan/process_evidence.ex` (`Event` struct + `export/2 :ocel2_json`); `reactor/durable/ledger_ocel.ex` emits from durable ledger | `lib/xaas/ocel/*` Ash domain (`Event`, `Object`, `EventObject`, `ObjectObject`, `ObjectStateDelta`), `projection.ex` OCEL 2.0 JSON project/import | `lib/beam4pm_ocel.ex` (query/encode/decode over generated types in `lib/beam4pm_types.ex`); ingest `beam4pm_ocel_ingest.ex`; WASM ops `ocel_add_event` etc. in `beam4pm_rust4pm.ex`; Ash mirror resources `beam4pm_ash/resources/ocel_*.ex` | `crates/wasm4pm-cognition/src/ocel/mod.rs` (`OcelLog`/`OcelEvent`/`OcelObject`); plus 3 extra divergent structs (`sa2a/ocel.rs`, `wasm4pm-testing/src/lib.rs`, `wasm4pm-sa2a-actuator/src/resource_ocel.rs`) |
| Event struct fields | `%Event{id, activity, timestamp, objects: [{type,id,qualifier} triples], attributes: map, subject_id}` | Ash row: `event_type, ocel_id, occurred_at, attributes: map` + `EventObject` join rows `(object_id, qualifier)` | `%OcelEvent{event_id, event_type, event_time, attributes: map}`; relationships are separate `OcelRelationship{qualifier, object_id}` E2O lists owned by event ingest pairs | `OcelEvent{event_id, activity, timestamp, attributes: BTreeMap, o2o: [(object_type, object_id)]}` — note: E2O folded into `o2o`, no per-relation qualifier |
| Activity/event type naming | snake_case verbs: `run_started`, `run_ended`, `task_succeeded`, `task_attempted`, `task_failed` | PascalCase catalog: `TurnStarted`, `ToolCallResult`, `PermissionResolved`, ... (generated `zcode_event_registry.ex`, 15 types) | OCEL 2.0 spec style: free string `event_type` (wire key `type`); catalog supplied per-log via `ocel_add_event_type` | Breed lifecycle kinds (`activity` = breed trace step kind); `sa2a.resource.actuation` dot-namespace in the actuator variant |
| Object types in use | `WorkflowRun`, `Step`, `Capability`, `Realization` | `session, turn, model_request, tool_call, permission, subagent, file` (7, generated) | Declared per-log via `ocel_add_object_type`; Ash mirror has generic OcelObject | `"run", "breed", "fact"` (e.g.) declared in `OcelLog.object_types` |
| Relationship model | inline triples `(type, id, qualifier)` per event | normalized join table + `qualifier` column | separate `OcelRelationship` list, `qualifier` present; referential integrity check `validate_envelope/2` | `o2o` only; E2O as unqualified `(type, id)` pairs — qualifier lost |
| Envelope format | OCEL 2.0 JSON: `objectTypes[{name,attributes}], eventTypes[{name,attributes[{name,type:"string"}}]}, objects[{id,type,attributes}], events[{id,type,time,attributes[{name,value}],relationships[{objectId,qualifier}]}]` — note attrs flattened to string name/value pairs, `subject_id` injected into attributes | OCEL 2.0 JSON: `objectTypes`/`eventTypes` as **bare string arrays** (not `[{"name":...}]` objects), `objects[{id,type}]`, `events[{id,type,time,attributes: raw map,relationships[{objectId,qualifier}]}]` | OCEL 2.0 JSON via hand-written `encode/1`/`decode/1` over generated codec (spec-shaped); plus wire ops `ocel_add_event` with `e2o: [object_id, qualifier]` pairs | OcelLog JSON: **snake_case keys** `object_types`, `event_types`, `objects`, `events`; timestamps constant `1970-01-01T00:00:00Z` + `logical_step` attribute (determinism gate, no wall clock) |
| Storage | pure export, no persistence | Postgres (`ocel_events` table), admitted `:record` action, non-empty relations enforced in `after_action` | in-memory ingest + optional ETS Ash mirror; no persistence layer of its own | in-memory log; lifecycle DFA conformance gate on top |
| Admission/gating | export only | `RelateEventToObjects` change refuses zero-object events; identities `(event_type, ocel_id)` | `validate_envelope/2` dangling-relationship refusal | `BreedLifecycleModel` DFA refuses non-conforming event sequences |
| Known single-point gaps | export-time timestamps on ledger path (documented honesty note); string-typed attributes only | eventTypes/objectTypes envelope not spec-shaped (bare arrays vs `[{"name"}]`) | — | 3 redundant event structs in one repo |

## Key Divergences (the N² drift the map item warns about)

1. **Envelope key style**: wasm4pm is snake_case (`object_types`); the three Elixir repos use spec camelCase — but xaas's `objectTypes`/`eventTypes` are bare `[string]` arrays where ash_pplan and beam4pm emit spec-shaped `[{"name":..., "attributes":...}]`. Three envelope dialects, not one.
2. **Qualifier handling**: ash_pplan/xaas/beam4pm carry per-relation `qualifier`; wasm4pm cognition `o2o` drops it (E2O folded into `o2o` as `(type,id)`).
3. **Attribute envelope**: ash_pplan flattens attributes to `[{name, value:string}]` (all string-typed, `inspect` fallback); xaas emits raw map; beam4pm spec-shaped; wasm4pm `BTreeMap<String, serde_json::Value>`.
4. **Event-type vocabulary**: four disjoint catalogs — snake_case workflow verbs (ash_pplan), PascalCase agent-session catalog (xaas), per-log declared (beam4pm), breed-lifecycle kinds (wasm4pm). Zero overlap today.
5. **Time semantics**: wasm4pm forbids wall clock (epoch + logical_step, determinism merge gate); the other three use real ISO8601 timestamps; ash_pplan's durable ledger path stamps export time with `seq` as authoritative order.
6. **Identifier schemes**: `run:<id>/<task>@<seq>` (ash_pplan), UUID `ocel_id` (xaas), free `event_id` (beam4pm), digest-keyed (wasm4pm testing/actuator).
7. **Intra-repo duplication**: wasm4pm has 4 separate OcelEvent structs (cognition, sa2a/ocel.rs, testing, sa2a-actuator) — the drift already exists inside a single repo.

## Single-Ownership Recommendation

xaas's `Xaas.Ocel` domain is the only admitted, transactional, persistence-backed OCEL kernel with a non-empty-relationship admission gate and spec-named top-level keys — closest to a canonical substrate. Recommend:

- **Owner**: `xaas` (`lib/xaas/ocel/*`) as the canonical OCEL vocabulary + persistence kernel.
- **Canonical envelope** = OCEL 2.0 JSON with spec-shaped `objectTypes`/`eventTypes` declarations (fix xaas's bare-array dialect toward the ash_pplan/beam4pm shape; ash_pplan's `ProcessEvidence.export/2` is already the closest-to-spec envelope).
- **Vocabulary substrate**: generated from one RDF ontology (xaas's `zcode_event_registry.ex` is already generated; extend that pattern fleet-wide — generate each repo's registry from one graph, per `dfcm-composition` G: ontology→code generation).
- **Consumers stay thin adapters**: ash_pplan's `LedgerOCEL`/`ProcessEvidence`, beam4pm's ingest, and wasm4pm's cognition layer become projections/adapters over the xaas kernel's envelope; wasm4pm's determinism gate (epoch + logical_step) is a profile/flag, not a fork.
- **In-repo cleanup (wasm4pm)**: collapse 4 OcelEvent structs to the cognition `OcelLog` shape (preserving the determinism profile) before any fleet unification.

## Files Touched (evidence paths)

- `/Users/sac/ash_pplan/lib/ash_pplan/process_evidence.ex`, `/Users/sac/ash_pplan/lib/ash_pplan/reactor/durable/ledger_ocel.ex`
- `/Users/sac/xaas/lib/xaas/ocel.ex`, `event.ex`, `projection.ex`, `lib/xaas/generated/zcode_event_registry.ex`
- `/Users/sac/beam4pm/lib/beam4pm_ocel.ex`, `beam4pm_types.ex`, `beam4pm_rust4pm.ex`, `beam4pm_ash/resources/ocel_event.ex`
- `/Users/sac/wasm4pm/crates/wasm4pm-cognition/src/ocel/mod.rs`, `crates/wasm4pm-planner/src/sa2a/ocel.rs`, `crates/wasm4pm-testing/src/lib.rs`, `crates/wasm4pm-sa2a-actuator/src/resource_ocel.rs`
