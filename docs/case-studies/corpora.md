# Canonical Corpora Plan (OCEL 2.0 Native Pipeline)

Status: PLAN (nothing downloaded; stages 1–3 unexecuted).
Scope: canonical public process-mining corpora for end-to-end case studies through
`AshPPlan.ProcessEvidence` export → admission → `Ex4pm` conformance
(`/Users/sac/ash_pplan/lib/ash_pplan/process_evidence/ex4pm.ex`).

## Why public logs

The existing test surface uses synthetic NDJSON (`self_conformance` fixture). Real corpora
expose shape mismatches (multi-object events, attribute globality, object type cardinality)
that synthetic logs never reach. BPI logs also carry real timestamps at second granularity
and 10k+ traces, which stresses the OCEL export serializer and the admission court at scale.

## Candidate corpora

### BPI Challenge 2017 — Domestic Declarations (already staged, not vendored)

- Source: 4TU.ResearchData, DOI `10.4121/uuid:5f3067df-f10b-45da-bdc9-6220c37a45f2`
  (part of BPI Challenge 2017 log set; also mirrored in `ex4pm` fixture tree read-only).
- Format: XES 1.0 (OpenXES 1.0RC7 generated), 10,500 traces / 56,437 events, 20 MB.
- License: CC BY 4.0 (4TU standard license for BPI 2017 set; attribution required).
- Fit: reimbursement-style flow (submit → approvals → payment), `org:resource`/`org:role`
  attributes map directly to OCEL 2.0 object types. This is the stage-2 target because a
  read-only copy already lives in the sibling repo's fixture tree — validation of the
  XES→OCEL conversion path with a known-good reader before a fresh download.

### BPI Challenge 2020 — Travel reimbursements / domestic declarations

- Source: 4TU.ResearchData, BPI 2020 set (Domestic Declarations
  `10.4121/uuid:5f3067df-f10b-45da-bdc9-6220c37a45f2` is actually the BPI 2017 subset; the
  BPI 2020 "Reimbursement" logs: RequestForPayment, International Declarations,
  Domestic Declarations — DOIs on 4TU per log).
- Format: XES, up to 10,500 traces (Domestic Declarations) / 7,065 traces (Request For
  Payment), tens of MB each.
- License: CC BY 4.0.
- Fit: same reimbursement shape, cleaner multi-object structure than 2017. Secondary target.

### BPI Challenge 2012

- Source: 4TU, DOI `10.4121/uuid:3926db30-f712-4394-aebc-75976070e91f`.
- 13,087 cases / 262,200 events, XES, ~170 MB, CC BY 3.0? — confirm license on the 4TU page
  before download (BPI 2012 predates the uniform CC BY 4.0 policy).
- Fit: largest stress corpus; stage-3 only, since the serializer + court cost at 262k events
  needs a benchmark budget first (see `bench/ocel_export_scaling_raw_w16.txt`).

### ocel-standard.org samples

- Source: https://www.ocel-standard.org — official OCEL 2.0 sample logs
  (e.g. `order-management`, `procurement`, `logistics`) in both JSON and SQLite formats.
- License: linked per-sample on the site (typically permissive/research-permitted; confirm
  per sample before vendoring).
- Fit: only corpora already in OCEL 2.0 native shape — no XES→OCEL conversion step, so they
  isolate the ash_pplan export semantics (attribute globality, event-to-object qualification)
  from conversion correctness. Stage-1-adjacent; the safest first external comparison point.

## Staged plan

### Stage 1 — ex4pm's existing fixture, end to end (no download)

Subject: `/Users/sac/ex4pm/test/fixtures/` (read-only, sibling repo; no copy into this repo
during stage 1 — reference by absolute path from a `@tag :integration` test).

Pipeline: build `AshPPlan.ProcessEvidence.Event` list → `AshPPlan.ProcessEvidence.Ex4pm
.export/2` to OCEL 2.0 JSON → parse back via `Ex4pm.OCEL.normalize/1` → admission court
(`AshPPlan.Standing`/receipt path) → ex4pm conformance check with real numbers.

Acceptance (real numbers, from the fixture inventory below):
- Domestic Declarations: 10,500 traces → ≥ 10,500 process instances in the export; 56,437
  events exported; conformance fitness reported by ex4pm ≥ 0 (reported value recorded here).
- `marketplace-ocel.json`: 15 events / 9 objects / 5 event types / 3 object types round-trip
  losslessly (all attribute keys survive).
- `self_conformance.ndjson` (30 lines): round-trips through export→normalize equality.
- Falsifier: export→parse round-trip loses any attribute key, or admission refuses a log
  that ex4pm conformance accepts.

### Stage 2 — one BPI log

Download BPI 2017 Domestic Declarations from 4TU (CC BY 4.0, 20 MB) into
`test/fixtures/case_studies/bpi2017_domestic_declarations.xes`, with a `LICENSE.md` in the
same dir stating provenance + attribution line. Attribution line: "BPI Challenge 2017
dataset, © CC BY 4.0, via 4TU.ResearchData."

Run the same pipeline as stage 1. Acceptance: trace count and event count match 4TU's stated
figures (10,500/56,437); conformance numbers recorded in this file; export wall-time and
memory recorded in `bench/` raw files.

### Stage 3 — cross-fleet case study

Same reimbursement process family across fleets: BPI 2017 declarations (stage 2 corpus) vs
BPI 2020 Request For Payment vs an ocel-standard.org sample, each exported by ash_pplan and
conformed by ex4pm; results compared in one case study doc under `docs/case-studies/`.
Acceptance: one doc, three corpora, per-corpus fitness + divergence table, all numbers from
real runs.

## ex4pm fixture inventory (read-only, /Users/sac/ex4pm/test/fixtures/)

| file | size | contents | license header |
|---|---|---|---|
| domestic_declarations.xes | 20,497,405 B | 10,500 traces, 56,437 events; BPI 2017 "Domestic Declarations"; OpenXES 1.0RC7-generated XES 1.0; attrs: concept:name, org:resource, org:role, time:timestamp, Amount, BudgetNumber, DeclarationNumber | none in file (OpenXES generator comment only) |
| sepsis.xes | 5,441,435 B | 1,050 traces, 15,214 events; Sepsis cases log (BPI-format, Mannhardt); XES | none in file |
| `marketplace-ocel.json` | 4,683 B | OCEL 2.0 JSON, 15 events / 9 objects / 5 eventTypes / 3 objectTypes; marketplace sample (place_order etc.) | none in file |
| `ocel/self_conformance.ndjson` | 30 lines | NDJSON OCEL-style events (`ocel:eid`, `ocel:activity`, `ocel:timestamp`, `ocel:omap`, `ocel:vmap`) | none in file |

No fixture carries a license header or LICENSE file in the fixture dir; before any fixture
is vendored into this repo, provenance + license must be added per stage 2's `LICENSE.md`
pattern.

## Guardrails

- Nothing downloaded in this wave (stage 1 needs no download).
- ex4pm fixture tree is read-only; stage 1 references it by absolute path with an
  `@tag :integration` test so CI without the sibling repo skips cleanly.
- Vendor-into-repo only at stage 2, with the attribution `LICENSE.md` next to the file.
- Confirm per-corpus license on the 4TU / ocel-standard.org page at download time; the
  license figures above are recorded from the dataset landing pages and must be re-verified
  against the live page before redistribution.
