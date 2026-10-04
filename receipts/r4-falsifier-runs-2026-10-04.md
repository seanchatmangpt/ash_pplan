# R4 Pack-Capability Falsifier Runs — 2026-10-04

ERRC R4: for each ledger handwritten candidate, does the named marketplace pack
actually express the module's semantics, or is the candidate misfiled?
Read-only falsification wave. No module or pack edited; no git operations.

Subjects (read on disk 2026-10-04, `/Users/sac/ash_pplan`):

| module | lines |
|---|---|
| `lib/ash_pplan/fond/synthesis.ex` | 283 |
| `lib/ash_pplan/workflow/project/hddl.ex` | 239 |
| `lib/ash_pplan/reactor/durable/counterfactual.ex` | 544 |
| `lib/ash_pplan/reactor/durable/ledger_ocel.ex` | 142 |
| `lib/ash_pplan/execution_receipt.ex` | 367 |
| `lib/ash_pplan/capability.ex` | 63 |

Packs (all in `/Users/sac/ggen-marketplace/packs/`, all EXIST — no MISSING PACK falsification):

- `planning-federation-pack` — templates: `planner_ir.json.tera` + 5 `*.py.tera`; `queries/model.rq`; `consumer/planning-federation/compiler/*.py`
- `process-intelligence-pack` — templates: `ocel_tap.{ex,py,rs,ts}.tmpl`; gates 010–080; `queries/compare-loops.rq`
- `ggen-ecosystem-ocel-pack` — templates: 3 `*.json.tmpl`; one Python script; ~50 SPARQL gates
- `receipt-provenance-unification-pack` — templates: 4 (Python validator/runner + 2 JSON); gates 01–05
- `graphlaw-ash-capability-pack` — 13 Elixir templates (`capability_*.ex.tmpl`, `result_*.ex.tmpl`, surface test); gates 010–180; `targets.toml` = `["ex"]`

## Verdict rows

| # | Module | Pack | Verdict | Basis |
|---|--------|------|---------|-------|
| 1 | `AshPPlan.FOND.Synthesis` | planning-federation-pack | **MISFILED** | Pack projects planner IR JSON + Python compiler artifacts; zero Elixir templates, zero algorithm code. `synthesis.ex:129-177` (backward attractor worklist) and `synthesis.ex:181-217` (strong-cyclic greatest fixpoint) implement the Cimatti et al. AIJ 2003 fixpoint algorithms with a predecessor-edge index (`synthesis.ex:121-127`). That is an algorithm over an in-memory `%FOND{}`, not a projection of admitted RDF individuals. No template class in the pack can express it; not "one template away". |
| 2 | `AshPPlan.Workflow.Project.HDDL` | planning-federation-pack | **MISFILED** | Pack's nearest analog is `templates/planner_ir.json.tera` (JSON IR). `hddl.ex:14-71` renders HDDL s-expression text from `%Model{}`; `hddl.ex:75-239` is a hand-rolled s-expression reader + the HDDL Court (`hddl.ex:117-155`). The pack has no text-dialect/s-expression template class and no court-differential semantics (render→parse→compare against model). Pack cannot express it; recommend HANDWRITTEN reclassification, UNSUPPORTED(generator-capability) for this pack. |
| 3 | `AshPPlan.Reactor.Durable.Counterfactual` | process-intelligence-pack | **MISFILED** | Pack generates OCEL event-tap *adapters* from `pi:MappingRule/EventSource/ChainPolicy` individuals (`templates/ocel_tap.ex.tmpl` SPARQL header, lines 1-8). `counterfactual.ex` is a scratch-store replay engine: change planning (`:104-223`), dependency-closure invalidation (`:226-244`), ledger-digest invariance (`:74-85`), Engine attempt loop (`:293-303`), seeded checkpoint copy (`:305-345`), event diff (`:491-533`). None of it is a projection of event-type RDF. Pack overlap is only that both mention OCEL; semantics disjoint. |
| 4 | `AshPPlan.Reactor.Durable.LedgerOCEL` | ggen-ecosystem-ocel-pack | **MISFILED (narrow PARTIAL)** | Pack emits one-shot JSON documents (OCEL 2.0 JSON + Project-memory upsert) for a single ggen-ecosystem manufacturing run — its own pack.toml scopes it to "one GGEN ecosystem manufacturing run". `ledger_ocel.ex:25-48` is a runtime exporter over any durable store (`events/3`, snapshot fast path `:29-38`), `export/3` and `digest/3` (`:113-132`). The only shared piece is the OCEL 2.0 JSON shape — already supplied locally by `AshPPlan.ProcessEvidence.export/2` (`ledger_ocel.ex:117`), and process-intelligence-pack's `ocel_tap.ex.tmpl` is the closer Elixir template (still adapter-shaped, not ledger-shaped). Recommend HANDWRITTEN. |
| 5 | `AshPPlan.ExecutionReceipt` | receipt-provenance-unification-pack | **MISFILED** | Pack generates Python artifacts: `unified_receipt_validator.py`, `qualification_runner.py`, JSON matrix/gate report (generated/ + templates/). It validates receipt JSON *documents*; it does not generate an Elixir struct/PROV-O N-Triples serializer. `execution_receipt.ex` is: struct + observe (`:228-251`), PROV-O N-Triples `to_rdf/2` with IRI/literal escaping (`:103-225`), digest canonicalization of refs/pids/structs (`:331-366`), `validate_identity/1` 40-hex anchoring (`:262-280`). No Elixir template in pack; no RDF vocabulary in pack ontology for prov:/p-plan: emission from a struct. |
| 6 | `AshPPlan.Capability` | graphlaw-ash-capability-pack | **PARTIAL** (closest fit of the six) | This is the only pack that projects Elixir modules from RDF (13 `.ex`/`.exs` templates, `targets.toml` = `["ex"]`). Its template family projects a *capability registry surface* (behaviour, registry, per-op modules, API, result structs, surface test — pack README "Outputs"). `capability.ex` (63 lines) is a struct + `parse/1` regex/family parser with a config-extensible family list (`capability.ex:9-26`, `:29-53`). A `Family.Name` parser struct is a small subset of what `capability_module.ex.tmpl`/`capability_registry.ex.tmpl` project, so the semantics are expressible — but the module is 63 lines with a config hook; template overhead likely exceeds the module. Not misfiled, not worth conversion on current evidence. |

## Summary

- GENERABLE: none.
- PARTIAL: `capability.ex` (pack covers the shape; conversion not justified by size).
- MISFILED: `fond/synthesis.ex`, `workflow/project/hddl.ex`, `durable/counterfactual.ex`, `durable/ledger_ocel.ex`, `execution_receipt.ex` — each against its ledger-named pack; recommend HANDWRITTEN.md reclassification with UNSUPPORTED(generator-capability) for the named pack in each case.

## Falsifier status

Falsifier for this wave: "pack can generate the module's semantics" — killed for
all six candidates on direct read of every template in each named pack. The
ledger's handwritten column stands as written; no conversion work orders should
be opened from these candidates.

Pinning courts consulted (read-only usage evidence): `test/fond_synthesis_test.exs`,
`test/workflow/hddl_court_test.exs`, `test/durable/counterfactual_test.exs`,
`test/durable/mutations/counterfactual_digest_mutation_test.exs`,
`test/durable/ledger_ocel_test.exs`, `test/execution_receipt_test.exs`,
`test/hardening/receipts_fuzz_test.exs`, `test/sa2a/capability_test.exs`,
`test/hardening/capability_policy_hardening_test.exs`.
