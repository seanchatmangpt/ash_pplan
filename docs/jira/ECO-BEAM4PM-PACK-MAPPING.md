# ECO: beam4pm-process-model-pack mapping vs handwritten LedgerOCEL

ERRC C7 prep, read-only lane, 2026-10-04.

- Pack: `/Users/sac/ggen-marketplace/packs/beam4pm-process-model-pack` v0.1.23
- Consumer file: `/Users/sac/ash_pplan/lib/ash_pplan/reactor/durable/ledger_ocel.ex`
  (142 lines, 6 public/impl functions)
- Consumer event struct: `AshPPlan.ProcessEvidence.Event`
  (`lib/ash_pplan/process_evidence/event.ex`):
  `id, activity, timestamp, objects [{type, id, qualifier}], attributes (map),
  subject_id`.

## Verdict: ADOPT-WITH-OVERLAY

The pack covers the wire/struct layer (OCEL 2.0 JSON) but not the emission
pipeline; the emission pipeline (ledger walk, seq ordering, digest) is
consumer-local residue. Overlay sketch at the end.

## Why not plain ADOPT

`ledger_ocel.ex` is not a struct module — it is a pipeline: store snapshot vs
fallback fetch, presorted vs sorted standing, monotonic `seq` ordering, the
`run_started`/`task_succeeded`/`run_ended` lifecycle, per-checkpoint sha256
output digests, and a content digest over the export. The pack projects
`bpm:RecordType` graphs into struct definitions and tests, not this pipeline.
The closest pack artifacts are `BeamPM.Types.OcelEvent`/`OcelObject`
(types template) and `BeamPM.OcelIngest.Router` (igniter ingest template) —
both decode/admit OCEL 2.0 JSON; neither emits from a standing ledger.

## Disposition table

### `Event` struct

- Consumer: `AshPPlan.ProcessEvidence.Event`
  (id/activity/timestamp/objects/attributes/subject_id)
- Pack: `beam4pm_types.ex.tmpl` -> `BeamPM.Types.OcelEvent`
  (from the `bpm:RecordType` graph)
- **PACK-NEEDS-EXTENSION**: pack struct is OCEL 2.0 JSON wire shape
  (objects as maps with relationships); consumer struct uses tuple
  objects + `subject_id`. Admit a `bpm:RecordType` for the evidence
  event carrying `subject_id` and tuple-qualifier rendering.

### OCEL 2.0 JSON export (`export/3` -> `ProcessEvidence.export/2`)

- Pack: `beam4pm_ocel_ingest.ex.eex` (ingest direction only),
  `BeamPM.Types` codec templates
- **PACK-NEEDS-EXTENSION**: pack handles decode/admit of OCEL JSON;
  the export direction (struct -> OCEL 2.0 JSON with
  eventTypes/objectTypes declarations) is not in the pack.

### Ledger walk + lifecycle events

- (`run_started`/`task_succeeded`/`run_ended`, seq ordering, snapshot
  vs fallback store read)
- Pack: none
- **CONSUMER-LOCAL RESIDUE**: the load-bearing honesty caveat
  (export-time timestamps, `seq` is authoritative order) lives here;
  keep handwritten.

### Per-checkpoint sha256 output digest

- Pack: none — **CONSUMER-LOCAL RESIDUE.**

### `digest/3` content digest over export

- Pack: `beam4pm_receipt_chain.ex.eex` (adjacent: chain over
  receipts, not ledger rows)
- **CONSUMER-LOCAL RESIDUE** (adjacent capability exists in-pack but
  not for ledger rows).

### Ontology-driven struct generation + Chicago tests

- Pack: core competence (`bpm:RecordType` -> structs + tests)
- **IDENTICAL (as capability)**: exactly what the pack projects.

## Courts pinning current shapes (falsifiers any adoption must keep green)

Grep `LedgerOCEL|ledger_ocel` under `test/`:

- `/Users/sac/ash_pplan/test/durable/ledger_ocel_test.exs` — exports the
  standing ledger as subject-bound OCEL evidence; typed refusal on unknown
  run; digest tamper-evidence.
- `/Users/sac/ash_pplan/test/durable/ledger_ocel_hardening_test.exs` (12 tests)
  — 10k-event bounded memory; concurrent appends; digest stability across
  stores/map-key order; nil outputs/subjects export cleanly; duplicate seq ->
  unique event ids; non-terminal runs omit run_ended; Dets store restart
  equivalence.
- `/Users/sac/ash_pplan/test/durable/semantic_reality_ocel_court_test.exs` —
  p-plan Step-ordered checkpoints, count == tape + lifecycle;
  `export/3` produces parseable OCEL 2.0 JSON with the four canonical keys;
  digest stability/mutation; typed refusal.
- `/Users/sac/ash_pplan/test/courts/ocel_v2_mapping_court_test.exs` — the
  tightest shape pin: OCEL 2.0 JSON conformance (event identity, eventTime,
  NCName activities), no dangling object refs, declared-attribute check
  (pinned known gap: `subject_id` injected by export without declaration),
  per-event `task`/`seq` attributes, `task_succeeded` as legal NCName,
  seq losslessness across string-typed scalars.
- `/Users/sac/ash_pplan/test/burn_in/tokyo_depeg/*`, `ocel_digest_endurance_test.exs`,
  `ocel_export_kill_test.exs`, `ocel_pipeline_soak_test.exs`,
  `canonical_court_test.exs`, `gcp_lifecycle_plan_court_test.exs`,
  `marketplace_sim_test.exs` — downstream courts citing the export/digest
  contracts (burn-in, stress, soak, sim).

## Pack gates run read-only (rdflib 7.6.0, ontology.ttl + qualification/consumer.ttl)

All 16 gates: 0 rows, 0 violations.

| Gate | rows | violations |
|---|---|---|
| 010_required | 0 | 0 |
| 020_field_type_enum | 0 | 0 |
| 030_field_type_cardinality | 0 | 0 |
| 035_field_type_ash_expr | 0 | 0 |
| 040_transition_actuation_admitted | 0 | 0 |
| 050_hand_authored_source_required | 0 | 0 |
| 060_hand_authored_source_kind_admitted | 0 | 0 |
| 070_hand_authored_source_ceiling | 0 | 0 |
| 080_engine_required | 0 | 0 |
| 090_engine_vocab_admitted | 0 | 0 |
| 100_cli_command_required | 0 | 0 |
| 110_cli_vocab_witnessed | 0 | 0 |
| 120_parity_corpus_admitted | 0 | 0 |
| 130_parity_check_required | 0 | 0 |
| 140_parity_vocab_admitted | 0 | 0 |
| 150_port_bridge_admitted | 0 | 0 |

Note: gate 110 requires witnessed invocations; rdflib reports 0 violations on
the pack's own graph, which is consistent with the witness facts being present
in `qualification/consumer.ttl`.

## Overlay sketch (ADOPT-WITH-OVERLAY)

1. Admit in ash_pplan's own ontology a `bpm:RecordType` for the evidence event
   (fields: `id, activity, timestamp, subject_id`, plus attribute pairs) and
   render the struct via `beam4pm_types.ex.tmpl`, keeping tuple objects as a
   named overlay rather than changing the pack struct.
2. Keep `ledger_ocel.ex`'s pipeline (ledger walk, lifecycle events, seq
   ordering, digests) handwritten as consumer-local residue, per
   `lib/HANDWRITTEN.md`.
3. Move `ProcessEvidence.export/2`'s OCEL 2.0 JSON rendering toward the pack's
   codec/ingest vocabulary, treating the `subject_id` declaration gap
   (pinned in the mapping court) as the named first fix.
4. Runbook: re-run the 16 pack gates + the court files above; all green
   is the adoption receipt.
