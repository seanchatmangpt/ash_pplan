# RA3b — SA2A contract/policy falsifier (2026-10-04)

Subject: `lib/ash_pplan/sa2a/policy_candidate.ex` (67 LOC),
`lib/ash_pplan/provider.ex` (36 LOC), re-falsified against the CURRENT
sa2a packs on disk (the e3 receipt named them zero-template husks —
that is stale) and a marketplace-wide contract/policy template scan.
Read-only subject: `/Users/sac/ash_pplan`; pack source:
`/Users/sac/ggen-marketplace/packs`.

Method: public surface enumeration per module, template-class comparison
against every Elixir-emitting template in the 7 sa2a packs plus a
marketplace-wide `@callback|behaviour` and `policy|contract` template
sweep. Verdicts: GENERABLE / PARTIAL / UNSUPPORTED.

## Public surface enumerated

`AshPPlan.SA2A.PolicyCandidate` (sa2a/policy_candidate.ex):
- `fond/2` (L9): hostile-opts normalization (L11) + `with` chain over
  `SubjectGuard.fetch/1` (L13), `fetch(request, :domain, :missing_domain)` (L14),
  `fetch(request, :initial, :missing_initial)` (L15),
  `AshPPlan.select_policy/3` (L17), candidate map construction
  (L18-28: formalism/authority :none/standing :candidate/planner_subject/attempts),
  `SubjectGuard.preserve/2` (L30), refusal wrapping (L32-33).
- `powl/2` (L37): with-chain over SubjectGuard.fetch, `fetch_binary` (L39),
  `AshPPlan.plan/1` (L40), `SubjectGuard.preserve/2` (L41-48),
  `:plan_not_found` refusal (L50).
- private `fetch_binary/3` (L55), `fetch/3` (L61).

`AshPPlan.Provider` (provider.ex): behaviour only — 8 callbacks
`id/0, capabilities/0, properties/0, evidence/0, cost/0, qualify/2,
realize/2` (L23-35) + types `requirement/1, context/1, realization/1`
(L13-20). No implementation.

## Template candidates examined (current packs on disk)

### sa2a packs

- sa2a-semantic-evidence-pack: NO LONGER a zero-template husk. It now ships
  `templates/lib/sa2a_evidence_contract.ex.tmpl`,
  `templates/test/sa2a_evidence_contract_test.exs.tmpl`,
  `templates/priv/sa2a-evidence-envelope.schema.json.tmpl`, and
  `projections/{elixir,rust}/template.contract.tmpl`. The Elixir contract
  template emits a static descriptor (`descriptor/0`, all literals from one
  RDF contract row) plus a single `admit/1` envelope pattern-match with
  digest-size guards and a `:REFUSED_SA2A_SEMANTIC_EVIDENCE` refusal.
  `projections/elixir/template.contract.tmpl` is a header-comment-only file
  (no Elixir body). Class = contract-descriptor echo + envelope admission
  gate. Zero overlap with runtime candidate manufacture.
- sa2a-bridge-pack: `sa2a-contract.ex.tmpl` (static identity map, `identity/0`),
  `sa2a-edge-catalog.ex.tmpl` + `ggen_igniter/templates/sa2a_bridge_edges.ex.eex`
  (row-loop edge catalog: `all/do_edges/by_port_op`), `sa2a-bridge-test.exs.tmpl`,
  `sa2a-errc.md.tmpl`, `sa2a-bridge-shacl.ttl.tmpl`. Class = static identity /
  catalog echo. No with-chain logic, no refusals, no runtime calls.
- sa2a-spark-dsl-pack, sa2a-governed-process-pack: zero templates
  (ontology/pack.toml only).
- sa2a-fastapi-pack: Python only (`sa2a_gateway.py.tmpl`).
- sa2a-chicago-court-pack: test-suite templates only (`.exs.tmpl`).
- sa2a-semantic-diataxis-pack: markdown/JSON doc templates only.

### Non-sa2a contract/policy-shaped Elixir classes (marketplace sweep)

- graphlaw-ash-capability-pack `capability_behaviour.ex.tmpl`: nearest
  behaviour-class analog. Emits a behaviour with `op/0, build_request/1,
  decode/1, run/2` wire-op callbacks + Refusal types. Disjoint from the
  provider contract's `id/capabilities/properties/evidence/cost/qualify/realize`.
- ash-r2rml-reactor-paas-pack `paas_contract.ex.tmpl`: actuator behaviour
  (single `actuate/1` callback) + refusing default impl + literal contract
  module. A 1-callback class, not an 8-callback provider contract.
- ash-runtime-integration-contract-pack `authority_gate.ex.tmpl` (3-clause
  `authorize/1` over one literal action), `policy_context.ex.tmpl`,
  cs2-canonical-pack `consumer_contract.ex.tmpl` (literal echo module):
  literal-echo / single-gate classes.

## Verdicts

### lib/ash_pplan/sa2a/policy_candidate.ex — UNSUPPORTED (generator-capability)

No template class in any sa2a or non-sa2a pack expresses runtime candidate
manufacture: with-chains over SubjectGuard fetch/preserve, calls into
`AshPPlan.select_policy/3` / `AshPPlan.plan/1`, hostile-opts normalization,
candidate map minting (authority :none / standing :candidate), and typed
Refusal wrapping. The nearest classes are contract-descriptor echoes
(sa2a-semantic-evidence), identity/edge-catalog echoes (sa2a-bridge), and
wire-op behaviour shells (graphlaw-ash-capability). Reopen trigger: any pack
shipping an Elixir template class that emits subject-preserved candidate
manufacture over runtime planner APIs (SubjectGuard with-chain +
select_policy/plan + typed refusals).

### lib/ash_pplan/provider.ex — UNSUPPORTED (generator-capability), re-confirmed

Row already UNSUPPORTED (ERRC R3, 2026-10-04) — verdict unchanged, row not
edited. Fresh evidence updates the R3 basis: nearest behaviour analog is now
graphlaw-ash-capability-pack `capability_behaviour.ex.tmpl` (op/build_request/
decode/run) and ash-r2rml-reactor-paas-pack `paas_contract.ex.tmpl` (single
`actuate/1`); neither expresses the 8-callback qualification contract
(id/capabilities/properties/evidence/cost/qualify/realize →
`AshPPlan.Realization`). No pack covers a provider-contract behaviour class.

## HANDWRITTEN.md effect

- sa2a/policy_candidate.ex row: `sa2a-semantic-evidence-pack candidate`
  (unknown) → UNSUPPORTED (generator-capability), dated 2026-10-04, this
  receipt. Edited (row state differed).
- provider.ex row: already UNSUPPORTED (ERRC R3); verdict matches; not edited.
- Queue: 26 rows / 30 files → 25 rows / 29 files (one row decremented).

Reopen triggers recorded: sa2a-semantic-evidence-pack gained Elixir templates
since E3 — any subject-preservation / candidate-manufacture template class
there reopens policy_candidate.ex (and, for the descriptor/admit class, could
eventually cover contract-echo modules, though none exist in lib/ today).
