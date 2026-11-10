# Planning corpus census

One line per planning artifact on disk (2026-11-07, lane D9). Kind comes from
each file's own `(:requirements ...)` header; used-by comes from a repo grep of
the file name (lib/test/bin/docs, planning/ itself excluded).

Files named in the D9 dispatch but absent from disk: `fastener_torque.fond.pddl`,
`avionics_bay.po.pddl`, `composite_cure.stnu`, `aog_turnaround.hddl`. Those
names occur only as illustrative examples in the PRD
(`docs/industrial-deliberation-and-durable-execution-subsystem-prd-ard.md`);
no `.stnu` or `.po` planning artifacts exist anywhere in the repo.

## Root domain files

| file | kind | used-by |
|------|------|---------|
| `ash_pplan_control_plane.hddl` | HDDL domain (`:typing :hierarchy`) | test/ash_pplan/htn_test.exs; docs/sjira/v26.10.8 inputs manifests |
| `fond_differential.hddl` | HDDL domain (`:typing :hierarchy`), single-line body | test/ash_pplan/htn_test.exs; docs/sjira manifests |
| `fond_tla_court.hddl` | HDDL domain (`:typing :hierarchy`) | docs/sjira manifests (no test references) |
| `ash_pplan_construction.fond.pddl` | FOND PDDL domain (`:non-deterministic`) | docs/sjira manifests (no test references) |
| `ash_pplan_downstream.fond.pddl` | FOND PDDL domain (`:non-deterministic`) | docs/sjira manifests (no test references) |
| `fond_tla_recovery.fond.pddl` | FOND PDDL domain (`:non-deterministic :typing`) | docs/sjira manifests (no test references) |

## planning/examples/ (workflow HDDL examples)

| file | kind | used-by |
|------|------|---------|
| `file_release.hddl` | HDDL workflow domain `wf-file_release` | test/ash_pplan/htn_test.exs; docs/sjira manifests |
| `ontology_only.hddl` | HDDL workflow domain `wf-ontology_only` | test/ash_pplan/htn_test.exs; docs/sjira manifests |
| `qualified_fulfillment.hddl` | HDDL workflow domain `wf-qualified_fulfillment` | test/ash_pplan/htn_test.exs; docs/sjira manifests |
| `selfhost.hddl` | HDDL workflow domain `wf-selfhost` | test/ash_pplan/htn_test.exs; docs/sjira manifests |
| `ultracode.hddl` | HDDL workflow domain `wf-ultracode` | test/ash_pplan/htn_test.exs; docs/sjira manifests |

## planning/archive/ (superseded v26.9.6/v26.9.7 planning)

See `planning/archive/README.md` (archived 2026-10-03 per docs/COMBINE-HARDEN-MAP.md).

| file | kind | used-by |
|------|------|---------|
| `ash_pplan_v26_9_6.hddl` | HDDL domain | docs/sjira manifests |
| `ash_pplan_v26_9_7.hddl` | HDDL domain | docs/sjira manifests |
| `deliver_semantic_execution_v26_9_7.hddl` | PDDL problem (domain ash-pplan-v26-9-7) | docs/sjira manifests |
| `ship_v26_9_6.hddl` | PDDL problem (domain ash-pplan-v26-9-6) | docs/sjira manifests; basename substring-matches release-receipt tests — verify before citing as a live consumer |
