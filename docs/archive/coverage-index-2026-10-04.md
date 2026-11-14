# Coverage Index 2026-10-04

Maps every test/court file landed or touched today to what it proves. Sources:
`git status --porcelain test/`, receipts/*.md dated 2026-10-04, docs/jira/ECO-*.md.
Format follows coverage-index-2026-10-03.md. Standing is honest to the receipts:
per-lane summaries in `receipts/fleet-wave-w25-2026-10-04.md` are
coordinator-relayed (no per-lane logs on disk), so "ALIVE" below always means
"ALIVE (relayed)" unless a named file-backed receipt says otherwise.

Gate convention: unless a row says otherwise, the gate for a test path is
`mix test <path>` from the repo root. Rows in other gate terms name the command.

## Standing legend

- ALIVE (relayed): covered by a w25 lane summary (courts 275/0, durable 301/0,
  hardening 279/0, workflow 300/0); coordinator-relayed, no file-backed log.
- PARTIAL: in-flight verification lane (integration ledger I1/I5) or lane
  PENDING in w25; no passing summary witnessed.
- UNKNOWN: WIP / un-admitted; blocked or unrun.

## New courts — test/courts/ (courts lane 275/0, relayed)

| test path | surface | gate | standing |
|---|---|---|---|
| test/courts/pplan_upstream_court_test.exs | upstream vocab: no private P-PLAN; vendored P-PLAN 1.3 / PROV-O pinned | default | PARTIAL (in-flight, ledger I1) |
| test/courts/gcp_lifecycle_plan_court_test.exs | sim 8-step P-PLAN TTL bridges to real execution | default | ALIVE (relayed) |
| test/courts/pack_inventory_court_test.exs | pack inventory pins gates/queries to pack contents, anti-vacuity legs | default | ALIVE (relayed) |
| test/courts/realization_adapter_court_test.exs | every ap:Realization (adapter, op) names an op the adapter implements | default | ALIVE (relayed) |
| test/courts/catalog_execution_court_test.exs | GENERATED Catalog.Projection / Plan execute for real at runtime | default | ALIVE (relayed) |
| test/courts/ontology_semantics_court_test.exs | catalog<->ontology, providers<->ontology vocabulary agreement | default | PARTIAL (conform-falsify 13/0 file-backed; court run not) |
| test/courts/semantic_compiler_court_test.exs | topology validated pre-build; valid plans compile into a Reactor that runs | default | ALIVE (relayed) |
| test/courts/semantic_provider_court_test.exs | ap:Provider/ap:Realization semantics; authority never exceeds :construct | default | ALIVE (relayed) |
| test/courts/dsl/pplan_court_test.exs | GENERATED pplan DSL expands to same Model as `Model.new` literal | default | ALIVE (relayed) |

## New courts — test/durable/ (durable lane 301/0 +10, relayed)

| test path | surface | gate | standing |
|---|---|---|---|
| test/durable/protocol_court_test.exs | TLA+/Stateright/Elixir from one ontology; tla-rs + Stateright diff + mutants | default | PARTIAL (in-flight, ledger I1/I4) |
| test/durable/runtime_contract_court_test.exs | 5 GENERATED RuntimeContract modules bind to real durable runs | default | PARTIAL (in-flight, ledger I1) |
| test/durable/saga_compensation_court_test.exs | generated saga compensate: typed undo events, LIFO rollback, real Store.Ets | default | ALIVE (relayed) |
| test/durable/semantic_reality_ocel_court_test.exs | LedgerOCEL evidence-export semantics over a real durable Runtime.run | default | ALIVE (relayed) |
| test/durable/pack_courts_harness_court_test.exs | harness: 86 zero-row cross-contract courts + 4 admission gates | bin/runtime-contract-courts | PARTIAL (in-flight, ledger I1) |

## New courts — test/workflow/ (workflow lane 300/0, relayed)

| test path | surface | gate | standing |
|---|---|---|---|
| test/workflow/evidence_hardening_court_test.exs | typed literal failures; observation failures sealed typed; anti-vacuity | default | ALIVE (relayed) |
| test/workflow/g1_corresponds_to_step_court_test.exs | G1: receipt prov correspondsToStep count == executed steps | default | ALIVE (relayed) |
| test/workflow/ash_reactor_extended_court_test.exs | generated AshReactorExtended adapter: ops resolve, real steps execute | default | ALIVE (relayed) |
| test/workflow/cross_product_e2e_court_test.exs | CapabilityCatalog x realizable providers, end-to-end | default | PARTIAL (in-flight I1; ZD11 = 837 pairs / 4 success / 833 typed-refused, diagnosis not gate) |
| test/workflow/semantic_reality_runtime_court_test.exs | README Quickstart rows pinned to real Reactor behavior | default | ALIVE (relayed) |
| test/workflow/semantic_reality_authority_court_test.exs | authority ceiling :construct; availability is not authority | default | ALIVE (relayed) |
| test/workflow/telemetry_middleware_court_test.exs | GENERATED Telemetry middleware fires around real steps, zero source change | default | ALIVE (relayed) |

## New courts — other suites

| test path | surface | gate | standing |
|---|---|---|---|
| test/reactor/generic_action_bridge_court_test.exs | Reactor-as-generic-action bridge runs via `Ash.run_action/1` | default | ALIVE (relayed) |
| test/ggen_pack_semantics_court_test.exs | every pack gates/*.rq PREFIX pinned to ontology vocabulary | default | PARTIAL (court run not file-backed; conform-falsify 13/0 is) |
| test/semantic_reality_state_machine_court_test.exs | illegal transitions refused BY Ash; real lifecycle resolved | default | ALIVE (relayed) |
| test/fond/semantic_reality_fond_court_test.exs | FOND validate/4, strong-cyclic synthesize/3, purity | default | PARTIAL (w25 fond lane PENDING) |
| test/standing/semantic_reality_standing_court_test.exs | Standing.verdict/3, receipt five-field contract, ladder vocab | default | PARTIAL (w25 standing lane PENDING) |
| test/petal_framework/ (vendored clone) | hook drift confined to expected 3 entries; syntax + export PASS | gate-petal-fw receipt | ALIVE (file-backed; compile SKIPPED, deps missing offline) |

## Marketplace-sim suites (untracked WIP — ledger I3)

| test path | surface | gate | standing |
|---|---|---|---|
| test/marketplace_sim/marketplace_sim_test.exs | e2e sim: real Reactor over real sim processes + durable run per usage | `mix test test/marketplace_sim/` | UNKNOWN (WIP; its compile breakage caused the DemonstrationCourt 4 FAIL edges; quiescent rerun P5 pending) |
| test/marketplace_sim/gcp_contract_court_test.exs | consumer court over checked-in gcp_generated_validation projection | `mix test .../gcp_contract_court_test.exs` | UNKNOWN (same WIP / compile state) |
| test/marketplace_sim/runtime_contract_reactors_court_test.exs | 5 RuntimeContract surfaces over a SECOND non-durable subject family | `mix test .../runtime_contract_reactors_court_test.exs` | UNKNOWN (same WIP / compile state) |

## Modified test files (touched today; lane-covered)

| test path | surface | gate | standing |
|---|---|---|---|
| test/ash_pplan_test.exs | facade + durable adapter baseline | default | ALIVE (relayed) |
| test/execution_receipt_test.exs | ExecutionReceipt + file provider + durable store | default | ALIVE (relayed) |
| test/manufacture_test.exs | manufacture / regeneration chain | default | ALIVE (relayed) |
| test/release_contract_test.exs | release contract incl. projection_catalog | default | ALIVE (relayed) |
| test/case_studies/case_study_numbers_test.exs | case-study numbers | default | PARTIAL (case_studies lane PENDING in w25) |
| test/hardening/fond_policy_fuzz_test.exs | FOND policy fuzz | default | ALIVE (relayed, hardening 279/0) |
| test/workflow/durable_runtime_test.exs | durable runtime facade | default | ALIVE (relayed) |
| test/workflow/observation_middleware_test.exs | observation middleware | default | ALIVE (relayed) |

## Context gates (file-backed, 2026-10-04)

| gate | result | receipt |
|---|---|---|
| bin/conform (SHACL) | CONFORMS=True, 812 triples, exit 0 | gate-ontology-2026-10-04.md |
| bin/conform-falsify | 13 counterexamples refused, exit 0 | gate-ontology-2026-10-04.md |
| priv/ggen/vendor/verify_lock.sh | OK, lock 503af6c2 | gate-ontology-2026-10-04.md |
| bin/ggen-verify | 6/7 PASS; workflow-pack FAIL (task_props zero rows), pre-existing | gate-ontology-2026-10-04.md |
| ontology mirror hashes (x3) | MATCH canonical 257b0cec | gate-ontology-2026-10-04.md |
| petal_framework clone health | HEALTHY (3/3 executed gates; compile SKIPPED) | gate-petal-fw-2026-10-04.md |
| DemonstrationCourt solo | FAIL attributed to marketplace_sim WIP, not timeout; rerun P5 pending | demonstration-court-classification-2026-10-04.md |

## ECO-* orders (docs/jira/, all GENERATED, base c42ee19)

All 9 (AS-CONFIG, ASHREACTOR-STEPS, EXT-AUDIT, IGNITER-COMPOSE,
PROVIDER-QUALIFICATION, REACTOR-DAG, REACTOR-GENERIC, SA2A-PACKS,
SAGA-COMPENSATE): standing UNKNOWN, no execution receipts (ledger L8).

## Summary

| standing | rows |
|---|---|
| ALIVE (relayed or file-backed) | 27 |
| PARTIAL | 9 |
| UNKNOWN | 3 |
| total | 39 rows |

Upgrade path: per-lane logs landing in bench/fleet/logs/ upgrade relayed-ALIVE
rows to file-backed ALIVE; the DemonstrationCourt quiescent rerun (ledger P5)
upgrades the marketplace_sim UNKNOWNs or refutes them.

## ERRC wave additions (2026-10-04, append-only)

Every path below was verified to exist on disk at append time. Sources:
receipts/integration-ledger-2026-10-04.md (ERRC lane), module docstrings,
bin/gate. Formerly-QUEUED rows were re-verified on disk before upgrade.

### ERRC courts landed

| test path | surface | gate | standing |
|---|---|---|---|
| test/courts/workflow_corpus_court_test.exs | consumer court for vendored workflow-corpus-pack: 21 gates over 12 fixture corpora, per-fixture negative variants, anti-vacuity mutation, oxigraph engine | default | ALIVE (relayed 7/0) |
| test/courts/law_validate_parity_court_test.exs | `ggen law validate` vs `bin/conform-falsify` parity via [law].shapes + N3 [law].rules (13/13 counterexample parity; sh:pattern + CORE_ONLY sh:sparql dialect facts pinned) | default | PARTIAL (in-file parity verdict; run not file-backed) |
| test/courts/ocel_v2_mapping_court_test.exs | OCEL 2.0 mapping lossless over a real durable run (schema re-derived in-test; 2 gaps pinned in docstring) | default | PARTIAL (court on disk; run not file-backed) |
| test/courts/igniter_gen_byte_identity_court_test.exs | igniter-pack generator byte-identity: determinism, diff-stability vs committed projection, anti-vacuity; chaos-pack ACP rows verified 10/10 byte-identical | default | ALIVE (file-backed, integration ledger C4) |
| test/courts/case_study_court_test.exs | `bin/case-study-step-soak` typed contract: sufficient deadline PASSes with measured cycles; sub-minimum deadline is typed SOAK_TOO_SHORT refusal, exit 3, pre-test | default | PARTIAL (court on disk; case-study chain exit 1 at head per alignment receipt) |

### Formerly queued — landed on disk (upgraded from QUEUED, 2026-10-04)

Every path below re-verified with `ls` at upgrade time. Counts are
coordinator-relayed (ledger R1/R2b/G3); no per-lane file-backed logs.

| test path | surface | gate | standing |
|---|---|---|---|
| test/courts/ggen_verb_gates_court_test.exs | law export determinism + BLAKE3 hash vs pinned baseline (test/courts/fixtures/law_export_baseline.txt); derive stability; explain diff; 7-surface registry drift pin; mutated-ontology anti-vacuity | default | ALIVE (relayed 5/0) |
| test/courts/standing_parity_court_test.exs | evidence-standing-pack vs SPARQL gate parity: invariant-by-invariant table with DRIFT rows both directions; corrupted-chain refusals (double seal, parent-hash, cross-chain, non-neutral standing); anti-vacuity | default | ALIVE (relayed 11/0) |
| test/courts/pack_chaos_court_test.exs | chaos-pack render: 6 invariant + 4 kill suites parseable Elixir, byte-identical determinism, 3 gates non-empty rows, anti-vacuity | default | ALIVE (relayed; 12/0 combined trio) |
| test/courts/pack_ashext_court_test.exs | ashext adapter render byte-matches committed adoption modulo mix format; determinism; 5 gates 0 rows; anti-vacuity gate 010 | default | ALIVE (relayed; 12/0 combined trio) |
| test/courts/pack_state_transition_court_test.exs | state-transition 4 templates marker-free; determinism; 5 gates read-only (0 rows or typed ENGINE-LIMIT); anti-vacuity rogue VerifiedState | default | ALIVE (relayed; 12/0 combined trio) |

### ERRC infrastructure

| surface | what it proves | receipt | standing |
|---|---|---|---|
| priv/ggen/vendor/{workflow-corpus-pack,ash-pplan-chaos-pack,state-transition-pack,evidence-standing-pack} | 4 ERRC packs vendored + registered; ontology.ttl non-empty in all four | priv/ggen/vendor/PACKS.lock.json; verify_lock lock 503af6c2 | ALIVE (file-backed, registrar item) |
| priv/ggen/semantic-gate-witness/ + bin/gate witness step | fail-closed gate<->witness court (per-gate negative evidence); deliberately no mf_sync recipe — court run is the step | bin/gate step wiring; ECO-SEMANTIC-GATE-WITNESS.md | ALIVE (surface verified on disk) |
| bin/gate receipt-chain-verify step | parent_hash + payload-hash chain court, fail-closed; drop detection via .chain-head.json | bin/gate (receipt_chain_verify) | PARTIAL (step present; full bin/gate run not file-backed) |
| ggen.toml [law] section | root-level `ggen law validate` surface: [law].rules N3 denial rules + [law].shapes; backs law_validate_parity court | ggen.toml:34; docs/jira/ECO-ASHEXT-ADDITION-VERDICT.md | PARTIAL (parity ACHIEVED per ledger E1; residue fix lane in flight) |
| ggen.exemptions.toml | pack-inventory exemptions sidecar (FM-CONFIG-002 unblocker); reader: pack_inventory_court_test.exs | integration ledger E1 | ALIVE (file-backed, named unblocker) |
| bin/gate provenance-verify step | verify_lock.sh re-hash + provenance.ttl packName/packOntologySha256 pair re-hash, fail-closed FAIL branch, no new deps | bin/gate:187-208 (provenance_digest_verify); ledger R2a | PARTIAL (step present on disk; full bin/gate run not file-backed) |
| test/courts/igniter/gen_workflow_court_test.exs | workflow-pack reactor generation: AST-based modify lane (not string append), AST-identical renders, determinism sha 4b9aec3a, typed cardinality refusal; real Igniter test project + tmp dir | default; ledger R2b | ALIVE (relayed) |
| receipts/r4-falsifier-runs-2026-10-04.md | R4 pack-capability falsifier: 6 ledger handwritten candidates vs 5 marketplace packs; 5 rows MISFILED + 1 narrow PARTIAL (LedgerOCEL); HANDWRITTEN reclassification recommended per row | receipts/r4-falsifier-runs-2026-10-04.md; ledger R4 | ALIVE (file-backed receipt; reclassification in flight) |
| lib/HANDWRITTEN.md | provenance ledger: 151 lib files = 31 GENERATED / 120 HANDWRITTEN, re-derivable enumeration command | integration ledger C2 | ALIVE (file-backed) |

### ERRC fixes

| file | fix | standing |
|---|---|---|
| lib/ash_pplan/process_evidence.ex | subject_id injected into every exported event; non-DateTime timestamps refused typed (`:invalid_timestamp`), not crashed | PARTIAL (on disk; court run not file-backed) |
| lib/ash_pplan/reactor/adapters/durable.ex | durable adapter @table/@ops: human_approve, event_await, state_await, schedule_deferred/scheduling_deferred, scheduling_wakeup, workflow_dispatch | PARTIAL (on disk; durable lane coverage is earlier-day) |
| priv/ggen/ash-pplan-workflow-pack/gates/100_task_props.rq | task_props gate rewritten for the retired task-level property (closes the ggen-verify workflow-pack zero-rows FAIL previously filed as pre-existing) | PARTIAL (on disk; ggen-verify rerun not file-backed) |
| test/burn_in/dets_reopen_soak_test.exs | soak ack-race contract: store may be durably AHEAD of the last ack, never behind; ACKED-run-lost across kill/reopen asserted | PARTIAL (on disk; soak receipt at receipts/tokyo-burn-in-2026-10-03.md predates) |

### ERRC docs (all present on disk)

| doc | topic |
|---|---|
| docs/jira/ECO-FOND-PACK-RECONCILIATION.md | FOND pack reconciliation order |
| docs/jira/ECO-BEAM4PM-PACK-MAPPING.md | beam4pm pack mapping order |
| docs/jira/ECO-TOKYO-PROMOTION.md | Tokyo per-file promotion classification (1 MUTANT / 6 SUPPORT) |
| docs/jira/ECO-ASHEXT-ADDITION-VERDICT.md | ash-extension-core-pack adoption verdict; E1 parity unblockers |
| docs/jira/ECO-PETAL-DEP-STRATEGY.md | petal_framework dependency strategy |
| docs/jira/ECO-SA2A-EXECUTION.md | SA2A execution order |
| docs/jira/ECO-SAGA-UPSTREAM-PR.md | saga upstream PR order |
| docs/jira/ECO-UPSTREAM-WORKFLOW-PACK.md | workflow-pack upstream sync order; R2 sync ALIVE on branch @ `9b961d454` |

### Wave-2 additions (verified on disk 2026-10-04, this indexing pass)

| surface | what it proves / carries | receipt | standing |
|---|---|---|---|
| docs/jira/ECO-GATE-CONVENTION-DECISION.md (R0) | gate-convention decision doc: directory-is-convention ruling,
overriding per-repo drift | file on disk | ALIVE (decision doc, on disk) |
| ggen_igniter ADR 0010 (R0) | `docs/architecture/adr/0010-gate-convention-directory-is-convention.md`
in /Users/sac/ggen_igniter: same ruling, cross-repo | file on disk | ALIVE (decision doc, on disk) |
| receipts/r4b-state-transition-falsifier-2026-10-04.md (R4b) | state-transition falsifier:
`lib/ash_pplan/state_machine.ex` verdict MISFILED -> typed UNSUPPORTED
(generator-capability); remaining rows PARTIAL named-residue | file-backed receipt | ALIVE (file-backed) |
| lib/HANDWRITTEN.md | provenance ledger queue now 33 rows / 37 files; 12 rows carry
`UNSUPPORTED (generator-capability)` receipts after R4/R4b/R5 reclassification | file on disk
(totals section 2026-10-04) | ALIVE (file-backed) |
| C2 witness trees | 22 witness files across two vendor packs:
priv/ggen/vendor/state-transition-pack/witnesses/ +
priv/ggen/vendor/evidence-standing-pack/witnesses/ (pass/ + fail/ per gate) | find-verified count 22 | ALIVE (on disk, counted) |
| bin/gate provenance-verify overlayPath fix | parser now handles overlay shape:
`tdbv:overlayPath` takes precedence over `packName` for overlay packs
(bin/gate ~251-263); step emits `provenance-verify: GREEN -- N digest(s) match`
(bin/gate:291) on success | bin/gate source | PARTIAL (fix + GREEN branch on
disk; fresh full bin/gate run not file-backed) |
| ggen.toml `[law]` swap landed | root `ggen law validate` profile: `[law].rules`
= ontology/law_parity.n3 + `[law].shapes`; bin/conform and bin/conform-falsify
now shell out to `ggen law validate`; conform-falsify pins 13/13 refusal parity
(ggen.toml:34; bin/conform:5; bin/conform-falsify:11) | ggen.toml; gate-ontology
receipt (conform-falsify 13/0 file-backed) | ALIVE (file-backed, 13/13) |
| acp-rows deletion + decision comment | priv/ggen/ash-pplan-chaos-pack-acp-rows.ttl
DELETED (E0/C0); ggen.toml carries the decision comment: content duplicated
in-tree dc: rows, zero executable consumers, C4 lane proved 10/10 byte-identical
renders. Superseded 2026-10-04 by the vendored `ash-pplan-chaos` pack
adoption (`ggen.toml` `[packs.ash-pplan-chaos]`) | ggen.toml ~160-169;
git status `D` | ALIVE (decision on disk; deletion
in dirty tree, uncommitted) |
| law_export baseline re-pin | test/courts/fixtures/law_export_baseline.txt:
triples=1043, graph_hash 22a708e3... re-pinned 2026-10-04 after root ontology
grew 953 -> 1041 (+marker-rule derivations); court
test/courts/ggen_verb_gates_court_test.exs pins BLAKE3 equality | fixture + court
source | ALIVE (relayed 5/0; fixture on disk) |
| evidence court subject pin | test/workflow/evidence_hardening_court_test.exs
pins `subject_id` = `sha256:` + 64 x `a`; every Evidence.prov call bound to it;
corrupt-receipt legs refuse typed | court source | ALIVE (relayed, workflow lane
300/0) |
| state_transition timeout | test/courts/pack_state_transition_court_test.exs
`@moduletag timeout: 600_000` (repo convention for slow shell-out courts; 60s
ExUnit default was the blocker) | court source | ALIVE (relayed; 12/0 combined
trio) |
| ash_reactor ETS wait | test/workflow/ash_reactor_extended_court_test.exs waits
for the old ETS table to clear before re-creating the in-test resource (table
identifier race, comment at ~line 72) | court source | ALIVE (relayed) |

## Closeout wave additions (2026-10-04, verified on disk / cited receipt)

| surface | what it proves | gate | standing |
|---|---|---|---|
| mix.exs test_load_filters (glob fix) | `test/petal_framework/` excluded
from the ExUnit glob (mix.exs:14-29); full test tree compiles past the
vendored phoenix EEx templates | full-tree compile witnessed in
demonstration-court receipt §"post test-glob fix" | ALIVE (file-backed;
the relayed 2250-test full-run figure is NOT witnessed) |
| R0 re-home (in-tree) | evidence-standing-pack gates/ empty, 8 gates +
literal_scan -> verify/; state-transition 010/020/050 -> verify/, witness
gates 030/040 remain; verify/cardinality.json in both | witness runs 22/22
both-way (marketplace commit c76220c2a) | ALIVE (on disk, verified) |
| test/courts/dsl/pplan_court_test.exs | GENERATED pplan DSL == literal
Model expansion (C1) | included in gate-cd courts+workflow re-gate | ALIVE
(file-backed 759/0; per-file 10/0 not separately receipted) |
| test/marketplace_sim/ re-gate | post-ERRC-wave shared surface does not
break the sim suite | `mix test test/marketplace_sim/` | ALIVE (file-backed
31/0, gate-marketplace-sim-b) |
| consolidated re-gate (gate-cd) | prior single failures (evidence subject
pin, verb-gates baseline, state_transition timeout, ash_reactor ETS) all
green | `mix test test/courts/ test/workflow/` (_build-gate-cd) | ALIVE
(file-backed 759/0) |
| bin/gate full rerun b | 10 FAIL steps all classified expected-set; 6 PASS
incl. receipt-chain-verify, pack-gate-witness-court | bin/gate | PARTIAL
(file-backed FAIL classification; fixes in flight) |
| upstream push-readiness | 3 branches READY / AWAITING-USER: a1c3de3cd,
9b961d454, d636106 | read-only audit receipt | ALIVE (file-backed; pushes
pending user) |
| GateVerify moduledoc (ggen_igniter f960d25) | ADR 0010 convention
committed upstream | git reflog | ALIVE (on disk, other repo) |
| P5 exit-code caveat | explicit EXIT=2 witnessed; sole failure =
bin/demonstrate lock REFUSED under cross-lane load | demonstration-court
receipt §caveat attempt | PARTIAL (clean exit-0 re-close needs quiescence) |
| vendor re-lock claim (dd4fc64d / 293 files / GREEN) | relayed claim |
no receipt or log on disk carries it | NOT-WITNESSED (live verify_lock:
OK, 9 packs, lock 503af6c2, HEAD WARN) |

## Latest wave additions (2026-10-04, verified on disk at append time)

| surface | what it proves | receipt | standing |
|---|---|---|---|
| bin/ggen-replay-court keyless-keying fix | keyless receipts (null source_hash/plan_hash) keyed by sha256 of sorted recorded file paths, so a keyless row supersedes only its keyless predecessor (bin/ggen-replay-court:147-155 comment); previously every historical keyless row was a permanent FAIL | fix on disk in bin/ggen-replay-court | PARTIAL (fix present; claimed 63->10 collapse + fresh rerun NOT file-backed; last witnessed run b: 92+3 FAIL, gate-bin-gate-2026-10-04b.md) |
| status_fsm.ex.eex + status.ex conversion | priv/ggen/ash-pplan-workflow-pack/templates/status_fsm.ex.eex renders lib/ash_pplan/reactor/durable/status.ex, which now carries the GENERATED ggen_igniter header (regen command in-header; manifest dir tmp/mf-statusgen) | files on disk; AST-identity court coverage via test/courts/igniter/gen_workflow_court_test.exs | PARTIAL (conversion on disk, status.ex mtime Oct 4 07:06; claimed 43 ontology rows NOT witnessed; on-disk st:Transition count is 30) |
| witness fixtures, both vendor packs | evidence-standing-pack/witnesses/ pass+fail = 14 files; state-transition-pack/witnesses/ pass+fail = 4 files; verify/ re-homed: evidence 8 files, state-transition 3 (010/020/050); evidence gates/ empty | counted on disk 2026-10-04 | ALIVE (on disk, counted; the earlier "22 witness files" figure is now 18 in the two named packs) |
| receipts/e2-falsifier-runs-2026-10-04.md | E2 pack-template coverage check over 175 Elixir templates in ~40 packs: fond.ex, compiler.ex, ash_pplan.ex et al. all UNSUPPORTED (generator-capability); zero class overlap, no conversion runbook needed | e2-falsifier-runs-2026-10-04.md | ALIVE (file-backed) |
| ggen.toml [law].gates | 51 gate paths under the [law] gates block (ggen.toml:43+); header note: `ggen law validate` evaluates rules+shapes only, gates gate sync | ggen.toml | ALIVE (on disk, counted 51) |
| bin/gate workflow-corpus-court step | fail-closed step running test/courts/workflow_corpus_court_test.exs (bin/gate:341-344, ERRC RAISE #2) | bin/gate source | PARTIAL (step present; full bin/gate rerun since gate-b not file-backed) |
| grouped commits 07cc823 / 243ca91 / 02723ba | gitignore lane-build roots + local state (07cc823); ERRC ECO-jira docs + receipts + coverage index + README/whats-new (243ca91); bench raw tees + fleet logs + soak numbers (02723ba) | git log; HEAD = 02723ba | ALIVE (file-backed, on HEAD) |
| e2b falsifier receipt | NOT LANDED: no receipts/e2b-* file exists | ls receipts/ at append time | skipped (absent) |

## Restoration wave additions (2026-10-04, verified on disk at append time)

| surface | what it proves | receipt | standing |
|---|---|---|---|
| sync.sh patch 2g (restore lane, in flight) | verify/ re-home + witnesses/ shield
section present in priv/ggen/vendor/sync.sh (sync.sh:383, "2g. verify/ re-home +
witnesses/ shield"); 18 witness fixtures previously counted across the two
vendor packs | sync.sh source; earlier counted row above | QUEUED (patch on
disk; re-materialized verify/witnesses re-verify not yet witnessed) |
| Placeholder wave, 5 vendor packs | FM-PACK-005 re-add hook re-materialized
templates/placeholder.tmpl in 5 packs: ash-pplan-chaos, ash-pplan-protocol-court,
semantic-gate-witness-court, tokyo-depeg-burn-in, workflow-corpus (ls-counted);
hook guards upstream placeholders win (sync.sh:83-95) | sync.sh:83-95 | ALIVE
(on disk, counted 5) |
| bin/conform + bin/conform-falsify | CONFORMS=True with 13/13 counterexample
refusals witnessed in gate-ontology receipt (812 triples at that run); a later
1272-triple figure is claimed but not file-backed | gate-ontology-2026-10-04.md
(CONFORMS=True 812, falsify 13/0) | ALIVE (file-backed at 812; 1272
NOT-WITNESSED) |
| [law] path-integrity | all 51 paths in the ggen.toml `[law].gates` block
exist on disk (51/51, while-read verified); 9 of the 51 are vendor gate paths;
9 pack entries in priv/ggen/vendor/PACKS.lock.json; provenance.ttl carries
overlayPath | ggen.toml; PACKS.lock.json (packs=9) | ALIVE (on disk,
51/51 exist) |
| Keyless-keying court fix | bin/ggen-replay-court keys keyless receipts by
sha256 of sorted recorded paths (bin/ggen-replay-court:147-155); last
file-backed bin/gate run shows 10 FAIL steps total (gate-b) | fix on disk;
gate-bin-gate-2026-10-04b.md | PARTIAL (claimed 63->10 keyless collapse NOT
file-backed; fresh rerun pending) |
| [law].gates 42 -> 51 | 9 vendor gates wired onto the [law] block;
state-transition witness gates 030/040 (pack gates/, witness-shaped) correctly
excluded; evidence-standing 030/040 verify/ gates included | ggen.toml gates
block; state-transition-pack/gates/ listing | ALIVE (counted 51; exclusion
verified by ls) |
| status.ex GENERATED conversion | lib/ash_pplan/reactor/durable/status.ex
carries the GENERATED ggen_igniter header with full regen command; totals
32 GENERATED / 119 HANDWRITTEN per the E2c re-count | file header;
lib/HANDWRITTEN.md (E2c entry); a hand copy at /tmp/status_handwritten.ex is
absent (transient, not evidence) | PARTIAL (header on disk; fresh regen run
not file-backed) |
| E2/E2b/E3 falsifier receipts | E2: 175 templates, UNSUPPORTED verdicts; E2b:
workflow/project/reactor.ex UNSUPPORTED after 300-pack scan; E3: subject/
evidence/corpus UNSUPPORTED, process_evidence GENERABLE with conversion runbook
(e3 receipt section 4); queue 29 -> 26 rows / 30 files | receipts/
e2-falsifier-runs / e2b-reactor-projection-falsifier / e3-falsifier-batch
-2026-10-04.md; lib/HANDWRITTEN.md:55 | ALIVE (file-backed) |
| state_machine.ex PARTIAL closure | verdict PARTIAL with named residue
(confirmed genuine conversion candidate, not reclassified) |
receipts/r4b-state-transition-falsifier-2026-10-04.md | ALIVE (file-backed) |
| gate-100 retirement note | workflow-pack verify/cardinality.json carries a
"RESOLUTION PATH (2026-10-04)" note: typed task_props FAIL is a KNOWN STANDING;
resolves when ggen_igniter DERIVED_ROWS parse support lands (26.10.3), then
promote the pending_derived_rows contract | cardinality.json:20 | ALIVE
(decision note on disk) |
| bin/gate step changes | --fast seconds-scale subset flag (bin/gate:17-23,
SKIP lines + tail report); workflow-corpus-court step (bin/gate:384-387); 3
court-step promotions from mix-test-only to unconditional steps: pack-chaos,
pack-state-transition, standing-parity (bin/gate:389-396) | bin/gate source |
PARTIAL (steps on disk; full bin/gate rerun not file-backed) |
| Grouped commits | 37bc291 (courts: protocol court + runtime-contract courts
+ marketplace_sim/web surface) on HEAD; 07cc823/243ca91/02723ba previously
filed; A/B/C/G/H group lanes pending quiescence; runtime-overlay gap flagged in
the closeout wave | git log HEAD at append time; rows above | ALIVE (D group
landed; remaining groups PENDING quiescence) |
| Overlay digest adjudication | COHERENT verdict and b54d1737 generated[0]
digest: grep over receipts/, PACKS.lock.json, provenance.ttl finds neither;
on-disk PACKS.lock generated[0] is provenance.ttl sha256 4409e26b | ls/grep
at append time | NOT-WITNESSED (claim contradicted by on-disk
PACKS.lock.json; re-record pending) |
| Final ggen-verify receipt | 14-pack surface: 9 PASS / 2 FAIL (workflow-pack
task_props, workflow-corpus f000) / 2 ENGINE-LIMIT (state-transition,
evidence-standing; sparql.ex 0.3.12 no EXISTS) / 1 verifier-crash
(ash-extension-core-pack SPARQL.Algebra.Expression) | receipts/
ggen-verify-final-2026-10-04.md (11-pack wrapper table + 3 direct
`mix ggen_igniter.verify --pack`) | ALIVE (file-backed) |

## RA4 closeout wave additions (2026-10-04, ls-verified at append time)

| surface | what it proves | receipt | standing |
|---|---|---|---|
| receipts/ra4-no-reopen-2026-10-04.md | no-reopen confirmations closing this cycle's
reopen sweep: standing/cached.ex + sj_bridge.ex (R5 markdown-only falsifier),
fond.ex (E2/E3), fond/corpus.ex + workflow-corpus-pack surface (E3, no
templates), state_machine.ex stays PARTIAL (R4b named residue); zero verdict
changes, zero rows reopened; lib/HANDWRITTEN.md dated note appended |
ra4-no-reopen-2026-10-04.md | ALIVE (file-backed) |
| E1–E4 / RA1–RA4 receipts on disk | present: e2, e2b, e3, r4, r4b, ra2, ra3;
absent: e1, e4, ra1, ra3a, ra3b (ls receipts/ at append time) — absent names
not cited anywhere | ls receipts/ | ALIVE (present, file-backed); absent =
skipped |
| pack_workflow_gates / provenance_baseline / 2-new-pack courts | NOT LANDED:
no test/courts/*workflow_gate*, *provenance*, *new_pack* files; no
provenance_baseline fixture outside law_export_baseline.txt | ls test/courts/
test/courts/fixtures/ | skipped (absent) |
| bin/ggen-replay-court keyless-keying fix (closeout re-verify) | keyless
receipts keyed by sha256 of sorted recorded paths (bin/ggen-replay-court
147-155); fix still on disk at closeout | fix on disk;
gate-bin-gate-2026-10-04b.md | PARTIAL (unchanged; fresh post-fix rerun still
not file-backed) |
| status.ex GENERATED conversion (closeout re-verify) | GENERATED ggen_igniter
header + regen command confirmed in-file at closeout; template
status_fsm.ex.eex present | file header;
priv/ggen/ash-pplan-workflow-pack/templates/ | PARTIAL (unchanged; fresh regen
run still not file-backed) | |
