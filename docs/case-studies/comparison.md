# comparison.md

# Capability Comparison: ash_pplan + ex4pm vs Commercial Execution Management (Celonis et al.)

Status: honest, artifact-cited. Every "present" status names the file that implements it; every gap is stated as a gap. Numbers are quoted only where a test asserts them. The commercial column describes typical capabilities of execution-management platforms (Celonis, Appian process intelligence, Salesforce process mining add-ons).

## Comparison Table

| Capability | Status here | Typical commercial capability |
|---|---|---|
| Event-log format | **Present** — OCEL 2.0 export implemented in `lib/ash_pplan/reactor/durable/ledger_ocel.ex`; the event log is emitted from the durable ledger, not hand-assembled. | First-class OCEL 2.0 / proprietary event-collection layer, multiple dialects, validated loaders. |
| Conformance checking | **Present** — `ex4pm/test/conformance_test.exs` asserts fitness == 1.0 and precision >= 0.9 on the reference log (lines 95–96). Fitness deviation detection also tested (lines 111–145). Attribution: ex4pm. | Alignments-based conformance with variant analysis, drill-down, tunable thresholds. |
| Process discovery | **Present** — inductive miner implemented in `ex4pm/lib/ex4pm_engine/inductive_miner.ex` (a second variant exists at `ex4pm/lib/ex4pm/engine/discovery/inductive_miner.ex`); discovers a process model from the event log. Attribution: ex4pm. | Inductive plus heuristics/alpha/split-miner variants, variant explorer, bottleneck views. |
| Receipts / evidence chains | **Present and differentiating** — `lib/ash_pplan/standing.ex` implements a three-layer verdict (plan / execution / consequence) combined by `verdict/3` into `:alive` or `{:lost, broken_layers}` (lines 43–56); `receipt/2` produces a replayable receipt. | At best immutable audit logs. Not replayable under an admission gate, no typed broken-term refusal, no per-step standing. |
| Timestamps / event-time fidelity | **Missing** — the OCEL export carries no export-time wall-clock stamp; recorded as a stated Limitation below. | Complete timestamps on every event and attribute, with timezone normalization and capture-time fields. |
| Root-cause / ML next-best-action | **Absent** — conformance yields numeric deviations only; no causal attribution. | Core selling point of the category. |
| Deviation-triggered action workflows | **Absent** — deviations are computed, not acted on; no action engine. | Core selling point (e.g. Celonis Action Flows). |
| Prebuilt connectors / ingestion | **Absent** — data arrives via the ledger itself; no connector framework. | Hundreds of prebuilt enterprise-system connectors and ready-to-run apps. |
| Ingestion at scale (incremental, schema drift) | **Absent** — no incremental ingestion or schema-drift handling. | Core platform feature (data jobs, transformations, incremental loads). |
| Product surface (UI: dashboards, case explorer) | **Absent** — capabilities exist as library code plus tests; no UI. | Full analyst-facing product UI. |

## Limitations (stated plainly)

- **Export-time stamps are missing.** The OCEL export from `ledger_ocel.ex` records event content but carries no wall-clock export-time field. Every commercial tool records capture time; this is a real gap, not a styling choice.
- **No connectors, no ingestion at scale.** There is no pull-based connector framework, no incremental load, no schema-drift handling.
- **No ML root-cause or next-best-action.** Conformance deviations are numeric, not causal.
- **No deviation-triggered action engine.** Deviations are computed but not automatically acted on.
- **Test-surface only.** Capabilities exist as library code and tests, not a product UI.

## The Honest Wedge

The wedge is not discovery, conformance, or dashboards — commercial platforms are ahead on all three as products. The wedge is **provenance-cryptographic evidence chains**: each process step is bound to a replayable, admission-controlled receipt with a three-layer plan/execution/consequence verdict (`Standing.verdict/3`, `lib/ash_pplan/standing.ex`), where commercial execution-management platforms rely on mutable audit logs that cannot be replayed under an admission gate. Where commercial tools detect a deviation and narrate it, this stack can certify a step as `:alive` or refuse it with typed broken terms — a different axis, not a weaker copy.

Connectors, ingestion at scale, ML actions, and dashboards are absent here and present there; that absence is not hidden, it is the scope of the claim. The honest wedge: take one differentiating axis (provenance-cryptographic evidence chains) and state plainly that everything else in the commercial bundle is either missing or test-surface only.

## Citations

- `lib/ash_pplan/reactor/durable/ledger_ocel.ex` — OCEL 2.0 export from the durable ledger.
- `ex4pm/test/conformance_test.exs` (lines 95–96, 111–145) — fitness 1.0 / precision >= 0.9 assertions; attribution: ex4pm.
- `ex4pm/lib/ex4pm_engine/inductive_miner.ex` (plus `ex4pm/lib/ex4pm/engine/discovery/inductive_miner.ex`) — inductive miner process discovery; attribution: ex4pm.
- `lib/ash_pplan/standing.ex` (lines 43–66) — three-layer verdict (`verdict/3`, `verdicts/1`) and receipt production.
