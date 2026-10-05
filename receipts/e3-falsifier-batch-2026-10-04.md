# E3 Falsifier Batch — 2026-10-04

Falsifier run (R4/E2 method) over the 5 modules named by the delta plan:
public surface (file:line) + template-class scan across
`/Users/sac/ggen-marketplace/packs/` (~300 packs). Read-only on source; the
only writes are this receipt and `lib/HANDWRITTEN.md`.

## Verdicts

| module | LOC | verdict |
|---|---|---|
| lib/ash_pplan/workflow/subject.ex | 278 | UNSUPPORTED (generator-capability) |
| lib/ash_pplan/workflow/evidence.ex | 236 | UNSUPPORTED (generator-capability) |
| lib/ash_pplan/fond.ex | 416 | UNSUPPORTED (generator-capability) — E2 re-confirmed |
| lib/ash_pplan/process_evidence.ex | 171 | **GENERABLE** (runbook below; row NOT reclassified) |
| lib/ash_pplan/fond/corpus.ex | 78 | UNSUPPORTED (pre-falsified: pack ships no templates) |

## 1. workflow/subject.ex — UNSUPPORTED

Public surface: `bind/1` (:13), `same?/2` (:30), `correspondence/2` (:35),
`verify_correspondence/3` (:56), `verify_projection/3` (:93), acyclicity core
`check_order`/`peel`/`cyclic?` (:143–189), `observe` multi-clause over
:pplan/:hddl/:fond/:reactor (:204–251). 40 def/defp.

Template-class scan: `cs2-exact-subject-pack` — sole templates are
`consumer-binding.ttl.tera` / `consumer-binding.ttl.tmpl` (TTL consumer-binding
echo); zero Elixir templates. Nearest Elixir subject template anywhere in the
marketplace: `ash-runtime-integration-contract-pack/templates/exact_subject.ex.tmpl`
— a 9-line static identity/exact? module (`identity/0`, `exact?/1` over pinned
repo/base/head). Zero overlap with a 278-LOC projection-verification library
(correspondence + projection order/acyclicity over :pplan/:hddl/:fond/:reactor).
No pack covers a projection-verification class.

## 2. workflow/evidence.ex — UNSUPPORTED

Public surface: `kinds/0` (:47), `telemetry_event/0` (:51), `profile/1` (:58),
`bind/2` (:80) with `bound?` over :receipt/:prov/:ocel/:telemetry (:141–149),
`plan_iri/1` (:119), `verify/2` (:125), `prov/3` (:164) → `render_prov`
PROV-O N-Triples serialization (:194), `ocel` doc build (:204), `telemetry`
(:224). 27 def/defp.

Template-class scan: `evidence-capital-realization-pack` — Python tests +
SPARQL gates only, zero templates. `sa2a-semantic-evidence-pack`
`sa2a_evidence_contract.ex.tmpl` emits a contract-literal echo + digest-size
admission clause — not evidence binding. `ash-runtime-integration-contract-pack`
`ocel.ex.tmpl` is a 7-line event factory (one function).
`evidence-standing-pack` `chain.ex.tmpl` (see §6) emits a hash-chain over es:
policy rows. Marketplace-wide scan for PROV-O / N-Triples emission in any
Elixir template: zero hits (all PROV/OCEL template hits are TTL / JSON /
Python / Rust). No template class emits PROV-O N-Triples serialization or
subject-bound evidence verification.

## 3. fond.ex — UNSUPPORTED (E2 re-confirmed)

Public surface: `new/2` (:48), `check/1` (:72), `actions/2` (:102),
`outcomes/3` (:111), `validate_policy/4` (:131) with strong / strong-cyclic
worklist validation (`strong_worklist` :342, `backward_worklist` :372),
`to_tla/5` (:159). 40 def/defp.

Template-class scan: planning-federation-pack templates are all Python
(`planner_ir.json.tera`, `projector.py.tera`, `interchange.py.tera`,
`binary.py.tera`, `catalog.py.tera`, `symbolic.py.tera`) plus JSON IR — zero
Elixir. Nearest Elixir analog, state-transition-pack `fsm.ex.tmpl`, is a
deterministic FSM; no nondeterministic-outcome / strong-cyclic /
TLA-rendering class exists. The E2 verdict stands; the row keeps its
2026-10-04 date and additionally cites this receipt.

## 4. process_evidence.ex — GENERABLE (runbook; row NOT reclassified)

Public surface: `events_from_receipt/3` (:23), `export/2` (:83, :96),
`ev/6` (:71), `valid_timestamp?/1` (:98), `export_valid/1` (:101),
`value_to_s/1` (:164). 9 def/defp.

**The falsifier fails here: a covering template class exists.**
`ash-ex4pm-evidence-pack/templates/process_evidence.ex.tmpl` renders per
`ex4ev:Emitter` row (`for_each: emitters`) and its own header comment states
it was "generalized from ash_pplan/lib/ash_pplan/process_evidence.ex +
process_evidence/event.ex". It emits behaviour + Event struct +
`events_from_receipt(receipt, subject, opts)` (attempted/succeeded/failed
pairs, dead-task cutoff), the pure OCEL 2.0 JSON export
(objectTypes/eventTypes/objects/events/relationships), and `digest/1`.
That covers the same class as the local module. Local-only supersets:
%ExecutionReceipt{} / %Event{} struct typing, `valid_timestamp?` and
`export_valid` guards (template guards only Jason availability).

### Runbook (draft — qualification before conversion)

1. In the consumer graph, declare an `ex4ev:Emitter` row for namespace
   `AshPPlan` (app/resource/action of the workflow resource).
2. Render with ggen against ash-ex4pm-evidence-pack; output lands at
   `tmp/d6/consumer/lib/ash_pplan/process_evidence.ex`.
3. Diff rendered vs local. Port local-only guards (`valid_timestamp?`,
   `export_valid`) into the pack template upstream-first, then re-render —
   never hand-edit rendered output.
4. Run the process-evidence tests and check call-site parity:
   `mix test` (process_evidence tests) +
   `grep -rn "AshPPlan.ProcessEvidence" lib test`.
5. Ensure the first 12 lines carry the GENERATED provenance marker, promote
   into lib/, and re-run this falsifier to close the loop.

### Why the row stays a candidate (not reclassified)

The delta plan's expected UNSUPPORTED does not hold for this module: the pack
template class covers it. An honest GENERABLE verdict blocks reclassification;
the row stays a candidate until the runbook executes and a qualification
receipt exists.

## 5. fond/corpus.ex — UNSUPPORTED (pre-falsified)

The delta plan's no-templates fact verified live:
`ls packs/workflow-corpus-pack/templates` → "No such file or directory"
(ENOENT). The pack ships ontology.ttl + gates/*.rq and no templates/ at all,
so generation is impossible a priori;
`AshPPlan.FOND.Corpus.seeded/2` (:10, seeded %FOND{} cases via
:rand.uniform_s) has no template to generate from. Secondary check:
`tokyo-depeg-burn-in-pack/templates/corpus.ex.eex` is a domain-specific depeg
burn-in corpus, class-disjoint. UNSUPPORTED.

## 6. Reopen triggers

- **evidence-standing-pack `chain.ex.tmpl` is the first Elixir template class
  in the standing/evidence domain** (emits `lib/es/chain.ex` from es:
  ChainPolicy / Phase / Standing rows). Any new es: template emitting
  ladder-admission or PROV-O serialization **reopens standing.ex /
  execution_receipt.ex** (and workflow/evidence.ex per §2).
- process_evidence.ex reopens if the §4 runbook fails qualification.
- workflow/subject.ex reopens if any pack ships an Elixir
  projection-verification template class (correspondence / order /
  acyclicity).
- fond.ex / fond/corpus.ex reopen if a pack ships a nondeterministic-outcome /
  strong-cyclic Elixir class, or a corpus-generator Elixir class,
  respectively.

## Totals after

- 4 rows UNSUPPORTED (subject.ex, evidence.ex, corpus.ex new; fond.ex
  re-cited), 1 GENERABLE (process_evidence.ex — runbook drafted, row stays a
  candidate). Candidate queue: 29 → 26 rows / 33 → 30 files.
- lib/HANDWRITTEN.md updated with the E3 bullet + reopen-triggers note.
