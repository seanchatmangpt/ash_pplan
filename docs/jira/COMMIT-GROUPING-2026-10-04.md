# COMMIT-GROUPING-2026-10-04

Commit-grouping plan for the current dirty tree at `9a89aac` (main).
Refreshed 2026-10-04 after the ERRC waves landed. Source data: `git status --porcelain`
(87 tracked-modified + ~200 untracked), `git diff --stat` (22,384+/8,099−).

Group order is the recommended commit order: each later group's green gate
assumes the earlier ones are staged/committed first.

---

## Group A — ontology + mirrors + receipts surface

Ontology as source, its mirrors, and the standing/witness fixtures they feed.
Must land before packs (pack gates SPARQL-compile against these terms).

**Files**
- `ontology.ttl`
- `ontology/shapes.ttl`
- `ontology/law_parity.n3` (new)
- `priv/ggen/ash-pplan-pack/ontology.ttl`
- `priv/ggen/ash-pplan-standing-pack/ontology.ttl`
- `priv/ggen/ash-pplan-standing-pack/verify/cardinality.json`
- `priv/ggen/ash-pplan-standing-pack/verify/150_untyped_refusal.unbound.rq` (new)
- `priv/ggen/ash-pplan-standing-pack/verify/160_standing_state_dangling.unbound.rq` (new)
- `priv/ggen/ash-pplan-standing-pack/verify/170_standing_only_on_outcome.unbound.rq` (new)
- `priv/ggen/ash-pplan-standing-pack/verify/fixtures/` (new)
- `priv/ggen/ash-pplan-workflow-pack/ontology.ttl`
- `priv/ggen/ash-pplan-workflow-pack/verify/100_task_props.unbound.rq`
- `priv/ggen/ash-pplan-workflow-pack/verify/cardinality.json`
- `docs/sjira/v26.10.3/ARD-PRD.ttl`
- `docs/sjira/v26.10.3/ECO-MAX-ARD.ttl` (new)
- `docs/sjira/v26.10.3/goal.ttl` (new)
- `docs/sjira/v26.10.3/sjira.ttl` (new)
- `docs/sjira/v26.10.3/ecosystem-gap-inventory.md` (new)

**Message**: `ontology: law_parity.n3 + ARD/sjira v26.10.3 promotion; standing-pack unbound-rq falsifiers + fixtures`

**Green gate**: `bin/gate` (ontology section) — or minimal:
`ggen law validate && mix test test/courts/ontology_semantics_court_test.exs test/courts/law_validate_parity_court_test.exs test/courts/standing_parity_court_test.exs`

---

## Group B — packs + vendor lock + ggen.toml/exemptions sidecar

All pack manifests, pack templates, workflow gates, the vendored packs under
`priv/ggen/vendor/`, `PACKS.lock.json` + `verify_lock.sh` + `provenance.ttl`,
and the new `ggen.exemptions.toml` sidecar that unblocks ggen parsing.
`ggen.toml` + `ggen.exemptions.toml` belong here (not a separate group I) —
the sidecar's reader court lives with the pack-inventory court (Group H), but
the config files themselves are pack plumbing.

**Files**
- `ggen.toml`
- `ggen.exemptions.toml` (new sidecar, [FM-CONFIG-002])
- `priv/ggen/vendor/PACKS.lock.json`, `provenance.ttl`, `sync.sh`, `verify_lock.sh`
- `priv/ggen/vendor/ash-extension-core-pack/`, `ash-pplan-chaos-pack/`, `ash-pplan-protocol-court-pack/`,
  `evidence-standing-pack/`, `semantic-gate-witness-court-pack/`, `state-transition-pack/`,
  `workflow-corpus-pack/`, `tokyo-depeg-burn-in-pack/pack.toml`,
  `tokyo-depeg-burn-in-pack/templates/placeholder.tmpl`,
  `tokyo-depeg-burn-in-pack/verify/` (new)
- `priv/ggen/ash-pplan-pack/pack.toml`, `templates/placeholder.tmpl`
- `priv/ggen/ash-pplan-standing-pack/pack.toml`, `templates/placeholder.tmpl`
- `priv/ggen/ash-pplan-workflow-pack/pack.toml`, `templates/placeholder.tmpl`,
  `gates/100_task_props.rq`, `gates/120_reactor_workflows.rq`, `121_reactor_tasks.rq`,
  `122_reactor_args.rq`, `123_reactor_surface.rq` (new),
  `verify/120–123 *.unbound.rq` (new), `templates/reactors.ex.eex` (new)
- `priv/ggen/ash-extension-core-pack/` (new)
- `priv/ggen/ash-pplan-dsl-pack/` (new)
- `priv/ggen/ash-pplan-reactor-mw-pack/` (new)
- `priv/ggen/ash-pplan-durable-chaos-pack/` (new: pack.toml, MANIFEST.md, template)
- `priv/ggen/ash-pplan-durable-tla-pack/` (new)
- `priv/ggen/ash-pplan-store-conformance-pack/` (new)
- `priv/ggen/ash-pplan-igniter-pack/templates/placeholder.tmpl`
- `priv/ggen/evidence-standing-pack/` (new)
- `priv/ggen/state-transition-pack/` (new)
- `priv/ggen/semantic-gate-witness/` (new: gate-court.toml, gates, generated, runners, witnesses)
- `priv/ggen/generated/protocol-court` (new) — generated court output; commit (court replays depend on it) but flag: generated-from-ontology, must track ontology drift (Group A).

**Message**: `packs: ERRC wave packs + workflow reactor gates + vendor lock refresh; ggen.toml exemptions sidecar (FM-CONFIG-002)`

**Green gate**: `priv/ggen/vendor/verify_lock.sh && mix test test/courts/pack_inventory_court_test.exs test/courts/pack_gate_mutation_court_test.exs test/courts/pack_gate_witness_court_test.exs test/courts/ggen_verb_gates_court_test.exs test/courts/pack_chaos_court_test.exs`

---

## Group C — lib runtime + DSL + runtime contract (core code)

Core lib code for the ERRC waves. `lib/HANDWRITTEN.md` documents the
generated-vs-handwritten split for exactly this code — include it here so the
receipt travels with the subject it describes.

**Files**
- `lib/ash_pplan.ex`
- `lib/ash_pplan/capability.ex`
- `lib/ash_pplan/catalog/projection_catalog.ex`
- `lib/ash_pplan/execution_receipt.ex`
- `lib/ash_pplan/process_evidence.ex`
- `lib/ash_pplan/providers/a2a.ex`
- `lib/ash_pplan/reactor.ex`
- `lib/ash_pplan/reactor/adapters/{durable,local}.ex`
- `lib/ash_pplan/reactor/adapters/ash_reactor_extended.ex` (new)
- `lib/ash_pplan/reactor/durable/{ledger_ocel,run}.ex`
- `lib/ash_pplan/reactor/durable/compensations/` (new)
- `lib/ash_pplan/reactor/middleware/observation.ex`
- `lib/ash_pplan/reactor/generic_action_bridge.ex` (new)
- `lib/ash_pplan/reactor/telemetry_middleware.ex` (new)
- `lib/ash_pplan/runtime_contract/` (new)
- `lib/ash_pplan/config.ex`, `lib/ash_pplan/dsl.ex`, `lib/ash_pplan/dsl/` (new)
- `lib/ash_pplan/standing/cached.ex`
- `lib/ash_pplan/workflow/dsl/extension.ex`
- `lib/ash_pplan/workflow/dsl/transformers/generate_model.ex`
- `lib/ash_pplan/deleted: fond/consumer.ex`, `reactor/steps/common.ex` (deletions)
- `lib/HANDWRITTEN.md` (new, 331 lines)
- `mix.exs`, `mix.lock` (petal dep gate for petal_framework exclusion + new deps)
- `.formatter.exs` (exports for the new DSL)

**Message**: `lib: runtime contract + generic action bridge + telemetry middleware + compensations; DSL surface; HANDWRITTEN.md split doc`

**Green gate**: `mix compile --warnings-as-errors && mix test test/courts/runtime_contract_court_test.exs test/durable/runtime_contract_court_test.exs test/workflow/ash_reactor_extended_court_test.exs test/reactor/generic_action_bridge_court_test.exs test/workflow/telemetry_middleware_court_test.exs test/durable/saga_compensation_court_test.exs`

---

## Group D — protocol court + marketplace_sim + web

`bin/manufacture-protocol-court`, its generated output already staged in Group B
(`priv/ggen/generated/protocol-court`), and the marketplace_sim/web test surface
(includes the browser gate receipts' subject).

**Files**
- `bin/manufacture-protocol-court` (new)
- `bin/manufacture-runtime-contract` (new)
- `bin/runtime-contract-courts` (new)
- `bin/case-study-step-soak` (new)
- `test/marketplace_sim/` (new incl. `web/`)
- `test/courts/gcp_lifecycle_plan_court_test.exs`, `test/courts/case_study_court_test.exs`,
  `test/courts/catalog_execution_court_test.exs`
- `test/support/marketplace_sim/` (new)

**Message**: `courts: protocol court + runtime-contract courts + marketplace_sim/web surface`

**Green gate**: `bin/manufacture-protocol-court && bin/runtime-contract-courts && mix test test/marketplace_sim`

---

## Group E — ERRC docs + receipts (wave bookkeeping)

All `receipts/*-2026-10-04*` files, the ECO-* jira docs, coverage index,
whats-new, audits. Pure documentation of the waves — commit as one bookkeeping
commit. `docs/jira/COMMIT-GROUPING-**2026-10-04.md**` (this file) lands here too.

**Files**
- `receipts/*.md` — all 30 untracked receipt files dated 2026-10-04
  (gate-*, r4*, ra*, alignment-wave, bench-triage, demonstration-court-classification,
  docs-lint(-fix), fleet-spot-check, fleet-wave-w25, integration-ledger,
  protocol-court-count-drift, sa2a-unsupported-applied)
- `receipts/marketplace-usage-evaluation.md` (modified)
- `docs/jira/ECO-*.md` (26 files, new)
- `docs/jira/coverage-index-2026-10-03.md` (M), `docs/jira/coverage-index-2026-10-04.md` (new)
- `docs/whats-new-2026-10-04.md`, `docs/gcp-lifecycle-simulation.md`, `docs/pplan-w3c-audit-2026-10-04.md`
- `docs/case-studies/receipts/*` (new: 2 case-study receipts + 4 o2c runs)
- `docs/case-studies/REPRODUCE.md`, `docs/demonstration.md`
- `docs/diataxis/reference/public-api.md`
- `docs/ontology-only-authoring.md`
- `README.md` (M, +273 lines)

**Message**: `docs: ERRC wave ECO-jira docs, 2026-10-04 receipts, coverage index, README/whats-new`

**Group E sub-decision (needs-human, open)**: `README.md` rewrites include
upstream-adjacent framing; if README is being prepared for upstream, split the
upstream-only framing into a follow-up commit before pushing beyond the private remote.

---

E-adjacent: `docs/jira/ECO-UPSTREAM-*.md`, `ECO-SA2A-UPSTREAM-PR.md`,
`ECO-ASHREACTOR-*.md` are upstream-adjacent docs — commitable as documentation,
but review before pushing to any upstream-visible remote.

---

## Group F — bench noise + logs + case-study numbers

Machine-generated bench outputs. Regenerable; safe to commit for the record or
skip entirely (needs-human call on whether w25 logs belong on main).

**Files**
- `bench/fleet/*` (modified: 4 json + 6 logs), `bench/ocel_w24_raw.txt`
- `bench/fleet/logs/fleet_all_w25.log`, `xaas.test.log.timeout` (new)
- `bench/hot_paths_raw_w25.json`, `bench/store_w23_raw.txt`, `bench/store_w24_raw.txt` (new)
- `test/case_studies/case_study_numbers_test.exs` (M)
- `test/fleet/ocel_pipeline_soak_test.exs` (M)
- `test/hardening/fond_policy_fuzz_test.exs` placement note: real hardening test, not
  bench noise — assigned to Group G in this rewrite (prior plan had it in F).

**Message**: `bench: w23/w24/w25 raw tees + fleet logs + soak numbers`

**Green gate**: `mix test test/case_studies/case_study_numbers_test.exs test/fleet/ocel_pipeline_soak_test.exs`

---

## Group G — test suite expansion (courts + hardening)

The ~40 new court tests under `test/courts/`, `test/durable/`, `test/fond/`,
`test/standing/`, `test/workflow/`, `test/ggen_pack_semantics_court_test.exs`,
`test/semantic_reality_*`, plus fixtures and support files. Modifications to
existing tests ride here too.

**Files**
- `test/courts/` — 20 new court tests: case_study, catalog_execution, gcp_lifecycle_plan,
  ggen_verb_gates, igniter_gen_byte_identity, law_validate_parity, ocel_v2_mapping,
  ontology_semantics, pack_ashext, pack_chaos, pack_gate_mutation, pack_gate_witness,
  pack_inventory, pack_state_transition, pplan_upstream, realization_adapter,
  semantic_compiler, semantic_provider, standing_parity, workflow_corpus;
  plus `test/courts/dsl/`, `test/courts/fixtures/`
- `test/durable/` new: `pack_courts_harness_court_test.exs`, `protocol_court_test.exs`,
  `runtime_contract_court_test.exs`, `saga_compensation_court_test.exs`,
  `semantic_reality_ocel_court_test.exs`
- `test/fond/semantic_reality_fond_court_test.exs` (new)
- `test/ggen_pack_semantics_court_test.exs` (new)
- `test/reactor/generic_action_bridge_court_test.exs` (new)
- `test/semantic_reality_state_machine_court_test.exs` (new)
- `test/standing/semantic_reality_standing_court_test.exs` (new)
- `test/support/marketplace_sim/` (new support files)
- `test/workflow/` new: `ash_reactor_extended_court_test.exs`, `cross_product_e2e_court_test.exs`,
  `evidence_hardening_court_test.exs`, `g1_corresponds_to_step_court_test.exs`,
  `semantic_reality_authority_court_test.exs`, `semantic_reality_runtime_court_test.exs`,
  `telemetry_middleware_court_test.exs`
- Modified tests riding here: `test/ash_pplan_test.exs`, `test/execution_receipt_test.exs`,
  `test/manufacture_test.exs`, `test/release_contract_test.exs`,
  `test/hardening/fond_policy_fuzz_test.exs`,
  `test/workflow/{durable_adapter,durable_runtime,evidence_court,observation_middleware,process_evidence}_test.exs`,
  `test/support/examples/**` (ontology + 5 workflow examples)
- `test/marketplace_sim/` + `test/support/marketplace_sim/` listed under Group D —
  they stay with D; do not double-commit.

**Message**: `test: ERRC wave courts (semantic-reality, gate-witness, parity, cross-product e2e, pack courts)`

**Green gate**: `mix test test/courts test/durable test/fond test/standing test/workflow test/reactor test/ggen_pack_semantics_court_test.exs test/semantic_reality_state_machine_court_test.exs`

**Message**: `test: ERRC wave courts (semantic-reality, gate-witness, parity, cross-product e2e)`

**Green gate**: `mix test test/courts test/durable test/fond test/standing test/workflow test/reactor`

---

## Group H — bin/ gate scripts + python parse helpers

Gate/bin plumbing for the ERRC courts (split from the prior plan's Group B
because bin/ has its own gate receipt: `receipts/gate-bin-gate-2026-10-04.md`).

**Files**
- `bin/gate`, `bin/ggen-doctor`, `bin/ggen-verify`, `bin/ggen-replay-court`, `bin/conform`,
  `bin/conform-falsify`, `bin/case-study`, `bin/manufacture`, `bin/manufacture-examples`,
  `bin/observe-ontology`
- `bin/.ggen-doctor-parse.py`, `bin/.ggen-verify-parse.py` (new, hidden parse helpers)
- `bin/dashboard`, `bin/dashboard_boot.exs` (new)
- `bin/__pycache__/` — **must NOT be committed** (see NOT-COMMIT list); the two
  hidden `.py` helpers SHOULD be, `__pycache__` should not. Add `bin/__pycache__/` to `.gitignore` first.

**Message**: `bin: gate/doctor/verify/replay-court refresh + dashboard + python parse helpers`

**Green gate**: `bin/gate && bin/ggen-doctor && bin/ggen-verify`

---

## Group I — .gitignore + snapshot-hygiene config

**Files**
- `.gitignore` (M: +3 lines)

**Message**: `gitignore: lane build roots + local state entries`

**Green gate**: `git status --porcelain` shows no untracked build-root entries after `git add -A --dry-run`.

---

## Cross-cutting files (appear in >1 concern — sequence, don't split the file)

| file | groups | note |
|---|---|---|
| `ggen.toml` | B (primary) | +157 lines referencing new packs; commits with packs |
| `ggen.exemptions.toml` | B | sidecar parsed by pack-inventory court (H); file rides with B |
| `mix.exs` / `mix.lock` | C | petal exclusion glob + new deps; rides with lib |
| `.formatter.exs` | C | DSL exports; rides with lib |
| `lib/HANDWRITTEN.md` | C | documents C's lib changes; rides with C |
| `priv/ggen/generated/protocol-court` | B + D | generated in B's pack sync, consumed by D's court |
| `ontology.ttl` | A | every pack gate in B compiles against A's terms — commit A first |
| `README.md` | E | upstream-adjacent framing — review before upstream-visible push |

---

## Needs-human / open decisions

1. **`test/petal_framework/` gitlink decision (STILL OPEN)** — full petal_components
   demo clone at HEAD `1d7fd4e` with its own `.git`. Options:
   (a) add as gitlink (submodule), (b) remove `.git` and vendor the tree,
   (c) gitignore it. `mix.exs` already excludes it from elixirc paths/globs, so (c)
   is cheapest; (a) is right if the demo must replay across machines. Until decided,
   leave it out of every group.
2. **README upstream framing** (Group E sub-decision).
3. **w25 bench logs on main** (Group F) — regenerable noise; confirm before committing.
4. **`priv/ggen/generated/protocol-court`** — commit generated output (court replays
   depend on it) vs regenerate-from-ontology; recommend commit + drift-check court.

---

## MUST NOT COMMIT

- `bin/__pycache__/` — python bytecode; gitignore it (Group H prerequisite).
- `test/petal_framework/` — until the gitlink decision lands (see Needs-human #1).
- `_build*/`, `deps/`, `doc/` — already ignored; do not force-add.
- `tmp/`, `/tmp` artifacts, `scratch/`, `tmp-*/` — ignored; do not force-add.
- `.ggen-v2` receipt caches — **not present in this tree** (checked; no matches),
  nothing to do. If one appears: ephemeral, gitignore, don't commit.
- `priv/ggen/.ggen_igniter/` — machine-local ggen_igniter state (already ignored).
- `.claude/settings.local.json`, `.claude/*.lock` — machine-local (already ignored).
- Lane build roots `_build-lane<N>` — ignored by the `/_build-*/` pattern; do not commit.
- `documentation/` — ex_doc output (already ignored).

---

## Report

- **Group counts**: A 19 files · B ~60 files (≈15 dirs + lock/provenance/sidecar)
  · C 30 files · D 11 files · E ~65 files · F 10 files · G ~45 files (enumerated)
  · H 14 files · I 1 file
- **Trickiest 3**:
  1. `test/petal_framework` gitlink decision — blocked group-wide; `mix.exs` exclusion
     makes it inert but uncommitted tree noise until decided.
  2. `priv/ggen/generated/protocol-court` — generated-artifact-in-tree vs
     regenerate-on-court-run; B↔D coupling.
  3. `ggen.exemptions.toml` sidecar + `ggen.toml` — pack-inventory court reads the
     sidecar, so B must be complete before H's court is green; a partial B commit
     red-gates the inventory court.
