# OCEL Vocabulary Audit — 4-Repo Surface Inventory

Date: 2026-10-03
Repos: `/Users/sac/ash_pplan`, `/Users/sac/xaas`, `/Users/sac/beam4pm`, `/Users/sac/wasm4pm` (plus `ex4pm`, the shared Hex dep, read from `/Users/sac/xaas/deps/ex4pm`)

Question: four repos each emit OCEL events. Do they speak one vocabulary, and if not,
who should own it?

## Inventory

### 1. ash_pplan — `AshPPlan.ProcessEvidence` / `LedgerOCEL`

Files:
`/Users/sac/ash_pplan/lib/ash_pplan/reactor/durable/ledger_ocel.ex`,
`/Users/sac/ash_pplan/lib/ash_pplan/process_evidence.ex`,
`/Users/sac/ash_pplan/lib/ash_pplan/process_evidence/event.ex`,
`/Users/sac/ash_pplan/lib/ash_pplan/process_evidence/{ex4pm,ash_ex4pm}.ex`

- **Internal event shape** (Elixir struct, `@enforce_keys [:id, :activity, :timestamp]`):
  `id` (string, e.g. `"run:<id>/<label>@<seq>"`), `activity` (e.g. `task_succeeded`,
  `run_started`, `run_ended`, `task_attempted`, `task_failed`), `timestamp`
  (`DateTime.t()`), `objects` (list of `{Type, Id, Qualifier}` 3-tuples, e.g.
  `{"WorkflowRun", "run:...", "run"}`), `attributes` (map, atom keys), plus a
  non-OCEL `subject_id` extension field.
- **Envelope** (`ProcessEvidence.export/2`, `:ocel2_json`): OCEL 2.0 JSON with
  **unprefixed** top-level keys `objectTypes` / `eventTypes` / `objects` / `events`
  (no `ocel:` namespace). Events: `{id, type, time, attributes, relationships}`;
  attributes rendered as `{name, value}` pair list; `subject_id` smuggled in as an
  attribute. Type declarations carry an `attributes` field (`{"name" => ..., "type" =>
  "string"}` per key). Object attributes always `[]`.
- **Timestamps**: `DateTime.to_iso8601/1` (always `Z` offset; ledger checkpoints carry
  no wall clock, so timestamps are export-time — honesty note in moduledoc).
- **IDs**: composite strings, deterministic (`run:<id>/<task>@<seq>`), not UUIDs.
- **Digest**: `LedgerOCEL.digest/3` — SHA-256 over `term_to_binary` of
  `{id, activity, attributes}` per event, lower-hex. Not over the exported JSON —
  changes with any output change but is not a digest of the envelope itself.

### 2. xaas — `Xaas.Telemetry.*` (emitter/forwarder/ndjson) + `Xaas.Ultracode.Ocel.Validator`

Files: `/Users/sac/xaas/lib/xaas/telemetry/ocel_ash_emitter.ex`,
`ocel_envelope.ex`, `ocel_forwarder.ex`, `ocel_ndjson.ex`,
`/Users/sac/xaas/lib/xaas/ultracode/ocel/validator.ex`

- **Internal event shape**: plain map, spec keys directly — `"id"` (UUIDv7 via
  `Ash.UUIDv7.generate/0`), `"type"` (`"<resource_short_name>.<action>"`, e.g.
  `book.create`), `"time"` (`DateTime.utc_now() |> to_iso8601`), `"attributes"`
  (string-keyed map, nils dropped), `"relationships"` (`{objectId, qualifier}` where
  qualifier = referenced object's type lowercased).
- **Envelope / wire (ndjson)**: each appended line is a **complete, individually
  conformant OCEL 2.0 JSON log** with `ocel:`-prefixed keys `ocel:objectTypes`,
  `ocel:eventTypes`, `ocel:events`, `ocel:objects`; declarations as `{"name": t}`;
  a line carries its own objects (relationship resolution is intra-document).
  Objects: `{id, type, attributes: {}, relationships: []}`.
- **Validation**: `Xaas.Ultracode.Ocel.Validator` — closed-vocabulary court: four
  required top-level keys, event requires `id/type/time/attributes`, object requires
  `id/type/attributes`, relationship requires `objectId/qualifier`, `time` must be
  ISO8601 zero-offset, types must be declared, no extra keys. `OcelNdjson` is the
  fail-closed assembler + tripwire against the legacy flat shape
  (`ocel:eid/ocel:activity/ocel:vmap/ocel:omap`), explicitly named in violations.
- **Digest**: none of its own; court reports (`event_count`/`object_count`), no
  content digest.

### 3. beam4pm — `BeamPM.Types.Ocel*` + `BeamPM.Ocel`

Files: `/Users/sac/beam4pm/lib/beam4pm_types.ex` (OcelEvent, OcelObject,
OcelRelationship, OcelAttribute, OcelPlanningEvent),
`/Users/sac/beam4pm/lib/beam4pm_ocel.ex`, `beam4pm_codec.ex`,
`beam4pm_ocel_ingest.ex`

- **Internal event shape**: generated structs with **different field names**:
  `OcelEvent{event_id, event_type, event_time, attributes}` (attributes itself a map
  of `OcelAttribute{attribute_name, attribute_value, recorded_at}` structs —
  attribute **changes**, not plain values). Relationships are a separate
  `OcelRelationship{qualifier, object_id}` struct, nested per-event/per-object at
  ingestion, not inside the event struct.
- **Envelope** (`BeamPM.Ocel.encode/1`): `{"objectTypes", "eventTypes", "objects",
  "events"}` — **unprefixed AND non-spec entity keys**: wire events are
  `{event_id, event_type, event_time, attributes}`, objects are
  `{object_id, object_type, attributes}`. No relationships in the encoded envelope;
  no `time` law; no declaration schema (`attributes: []` stubs). This envelope would
  fail both xaas's court and real OCEL 2.0 schema validation.
- **Validation**: referential only — `validate_envelope/2` (dangling
  relationship check). No closed-vocabulary court.
- **IDs/timestamps**: strings, opaque; no format law (`event_time` is any string).
- **Digest**: `OcelPlanningEvent.object_binding_digest` — a planning-specific
  digest field, not a log digest.

### 4. wasm4pm — Rust `OcelEvent` / `ResourceOcelEvent`

Files: `/Users/sac/wasm4pm/crates/wasm4pm-planner/src/sa2a/ocel.rs`,
`/Users/sac/wasm4pm/crates/wasm4pm-sa2a-actuator/src/resource_ocel.rs`

- **Internal event shape**: serde structs, **flat domain records, not OCEL entities**:
  `OcelEvent{event_type, subject, effect_id, provider, outcome}` and
  `ResourceOcelEvent{event_type, object_type, object_id, effect_digest, replay_key,
  generation, state}`. No `time`, no `id`, no relationships, no attributes map.
  Serializes with serde field names (`event_type`, ...) — its own dialect, related
  to OCEL only by the module name. OCEL 2.0 encode/decode "only exists inside the
  RF3 Rust oracle via two fixed wire ops" (beam4pm moduledoc).

### 5. ex4pm (shared dep, on Hex) — the closest thing to a shared law

`/Users/sac/xaas/deps/ex4pm/lib/ex4pm/ocel.ex`, `ocel2.ex`

- `Ex4pm.OCEL.normalize_event/2` accepts **every historical alias**: `id|:id|
  ocel:eid|:"ocel:eid"` for event id, `activity|type|ocel:activity` for activity,
  `timestamp|time|ocel:timestamp` for time, `ocel:oid/ocel:type` for objects,
  `qualifier|role|type` for relationships (default `"involved"`/`"related"`).
  Normalizes into `Ex4pm.Event{id, activity, timestamp, object_ids, relationships,
  attributes}`.
- `Ex4pm.OCEL.validate_envelope/1` and `Ex4pm.OCEL2` provide whole-envelope
  handling. ex4pm is deliberately permissive-normalizing, not a strict court.

## Comparison table

| Dimension | ash_pplan | xaas | beam4pm | wasm4pm | ex4pm (dep) |
|---|---|---|---|---|---|
| Internal event repr | struct `%Event{id, activity, timestamp, objects, attributes, subject_id}` | map with spec keys | structs `OcelEvent{event_id, event_type, event_time, attributes}` | serde structs (flat domain fields) | struct `Ex4pm.Event{id, activity, timestamp, ...}` |
| Event id field | `id` (deterministic composite `run:x/task@seq`) | `"id"` (UUIDv7) | `event_id` (opaque string) | none | `id` (string) |
| Activity/type field | `activity` (snake atoms→string) | `"type"` (`res.action`) | `event_type` (string) | `event_type` | `activity` (aliases incl. `type`) |
| Time field | `timestamp` (DateTime, export-time honest note) | `"time"` (ISO8601 UTC, zero-offset law) | `event_time` (any string, no law) | **absent** | `timestamp` (aliases incl. `time`) |
| Attributes | map, atom keys, `{name,value}` pairs in export | string-keyed map (nils dropped) | `OcelAttribute` change-list (`attribute_name/value/recorded_at`) | flat fields, no map | flattened map |
| Relationships | 3-tuples `{Type,Id,Qualifier}` → `{objectId, qualifier}` | `{objectId, qualifier}` (qualifier = object type lowercased) | separate struct, nested per owner, **dropped in encode** | **absent** | `ObjectRelationship{qualifier, object_id}` |
| Envelope top keys | `objectTypes/eventTypes/objects/events` (unprefixed) | `ocel:*` prefixed (spec) | `objectTypes/eventTypes/objects/events` + non-spec entity keys | none (private dialect) | both dialects normalized |
| Type declarations | `{"name", "attributes":[{name,type}]}` | `{"name"}` | `{"name", "attributes":[]}` | none | — |
| Strict conformance court | none (self-export, unvalidated) | **yes** (`Xaas.Ultracode.Ocel.Validator`, closed vocab) | dangling-rel only | none | permissive normalize + basic envelope check |
| Digest logic | SHA-256 over `{id, activity, attributes}` term_to_binary, lower-hex | none | `object_binding_digest` field only | `effect_digest`/`replay_key` fields | none |

## Divergences that matter

1. **Envelope namespace split**: xaas emits `ocel:`-prefixed keys (spec-correct);
   ash_pplan and beam4pm emit unprefixed `objectTypes/...`. Ash_pplan's export is
   actually the **OCEL 2.0 JSON schema's** unprefixed form for the *file* format —
   but beam4pm's entity keys (`event_id` vs `id`, `event_time` vs `time`) violate
   both dialects. Three spellings of "OCEL 2.0 JSON" exist in the fleet.
2. **No shared internal event type**: struct fields (`activity` vs `event_type` vs
   flat Rust fields) differ everywhere; only ex4pm's normalizer speaks all aliases,
   and nothing consumes it as the canonical vocabulary — each repo re-states its own.
3. **Time law exists in exactly one repo**: only xaas enforces ISO8601 zero-offset.
   ash_pplan emits export-time stamps (documented honesty note); beam4pm and wasm4pm
   have no time field or no law.
4. **Relationships**: three shapes (tuple triples; maps; separate structs dropped at
   encode). beam4pm's encoder silently drops relationships — a
   referential-integrity-checked shape that never reaches its own wire format.
5. **One court, four producers**: only xaas has a strict conformance validator, and
   it lives in an application, not the shared dep — the other three producers are
   unvalidated by any shared law. The court and the vocabulary are in different repos.
6. **Digest semantics differ**: ash_pplan digests event content; beam4pm/wasm4pm
   carry per-record digests (`object_binding_digest`, `effect_digest`); xaas has
   none. No cross-repo comparable log digest exists.

## Single-ownership recommendation

**Owner: ex4pm.** It is already (a) the shared Hex dependency of the Elixir repos
(ash_pplan's deps just moved to a Hex pin, commit `dbeddf6`), (b) the only module
that already normalizes every historical alias (`ocel:eid`/`id`/`activity`/`type`/
`time`/`timestamp`), and (c) dependency-free relative to all four consumers. The
vocabulary law should live where the normalization law already lives.

Concrete shape:

1. **Promote the vocabulary into ex4pm as the single normative module** (e.g.
   `Ex4pm.OCEL.Vocabulary`): the event/object/relationship field names, the
   `ocel:`-prefixed envelope keys, the ISO8601 zero-offset time law, the qualifier
   rule, and the required-key lists — sourced from xaas's validator (the strictest
   existing court) and ash_pplan's deterministic-id/`{Type,Id,Qualifier}` object
   convention.
2. **Upstream `Xaas.Ultracode.Ocel.Validator` into ex4pm** (it is app-agnostic; its
   only dependency is JSON decode). xaas then re-exports from the dep, keeping its
   ndjson assembly local. This closes the court/producer split (divergence 5).
3. **Consumption mode per repo**:
   - **ash_pplan, xaas, beam4pm: hex dep + schema pin** (C03 standing-addressed
     dependency: pin to the newest SHA whose court receipt is CONFORMANT, not a
     version number). ash_pplan switches `ProcessEvidence.export/2` to emit the
     `ocel:`-prefixed envelope; beam4pm remaps `event_id/event_type/event_time` →
     `id/type/time` at the `BeamPM.Ocel.encode/1` boundary and stops dropping
     relationships.
   - **wasm4pm: vendor, not dep** — it is Rust and cannot take an Elixir hex dep.
     Vendor the JSON Schema of the envelope (generated from ex4pm's vocabulary
     module) into `wasm4pm/crates/` and validate serde output against it in CI
     (plus add `id` and `time`, which its current structs lack entirely).
4. **Do not** make xaas the owner: it is an application, and pinning three repos to
   an app module inverts the dependency direction. Do not vendor into the Elixir
   repos either — the dep boundary already exists and works (Hex pin, commit
   `dbeddf6`).
5. Optional hardening: add a log-content digest (ash_pplan's SHA-256 over normalized
   events) to ex4pm so all four repos emit comparable digests — today no two repos'
   digests are inter-computable.

## Key file paths

- `/Users/sac/ash_pplan/lib/ash_pplan/process_evidence.ex` (export, unprefixed keys)
- `/Users/sac/ash_pplan/lib/ash_pplan/reactor/durable/ledger_ocel.ex` (digest)
- `/Users/sac/xaas/lib/xaas/telemetry/ocel_ash_emitter.ex` (UUIDv7, `ocel:*` ndjson)
- `/Users/sac/xaas/lib/xaas/telemetry/ocel_ndjson.ex` (assembler/tripwire)
- `/Users/sac/xaas/lib/xaas/ultracode/ocel/validator.ex` (the one strict court)
- `/Users/sac/beam4pm/lib/beam4pm_types.ex` (`BeamPM.Types.Ocel*`, ~line 11962)
- `/Users/sac/beam4pm/lib/beam4pm_ocel.ex` (encode drops relationships)
- `/Users/sac/wasm4pm/crates/wasm4pm-planner/src/sa2a/ocel.rs`
- `/Users/sac/wasm4pm/crates/wasm4pm-sa2a-actuator/src/resource_ocel.rs`
- `/Users/sac/xaas/deps/ex4pm/lib/ex4pm/ocel.ex` (alias normalizer, recommended owner)
