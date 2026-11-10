# Landing Manifest 2026-11-07 (Lane Y2)

Standing: PARTIAL_ALIVE

- Census method: pure filesystem mtime (all files `>= 2026-11-06 00:00`, all verified 2026-11-07); no git state commands — coordinator owns git.
- Syntax scan: `Code.string_to_quoted` over every `.ex` modified since 11-06 in both repos, run ~14:30: **ash_pplan scanned=101 ok=101 fail=0; ash_a2a scanned=17 ok=17 fail=0**.
- Mid-flight hazard witnessed: `lib/ash_pplan/reactor/durable/store/wal.ex` failed compile with a delimiter error at ~14:25 and was repaired by its owning lane at 14:21:50 mtime; re-scan passes. Lanes were still writing during this census — coordinator should re-run the syntax scan immediately before staging.
- Test gates below are PROPOSED, not executed by Y2.

## Repo 1: /Users/sac/ash_pplan — 357 files touched

### (a) Durability / W-surface repairs
lib: `lib/ash_pplan/reactor/durable/` (checkpointed, counterfactual, engine, health_gate, lease_monitor, migration, records, ring_buffer, run, store, store/{dets,ets,wal}, unwind), `lib/ash_pplan/fond/` (differential, policy_supervisor, policy_supervisor/offers, policy_switch, projection, recovery, replay, subject, supervision_session, synthesis, tla, trace), `lib/ash_pplan/obligation.ex`, `lib/ash_pplan/state_machine.ex`, `lib/ash_pplan/htn.ex`, `lib/ash_pplan/fond.ex`, `lib/ash_pplan/execution_receipt.ex`, `lib/ash_pplan/standing/receipt.ex`, `lib/ash_a2a` — n/a here; also `lib/ash_pplan/workflow/{evidence,subject}.ex`, `lib/ash_pplan/frontier_evidence.ex`, `lib/ash_pplan/workflow/project/hddl.ex`, `lib/ash_pplan/release_receipt.ex`, `lib/ash_pplan/oban.ex`, `lib/ash_pplan.ex`, `lib/ash_pplan/config.ex`.
test: `test/durable/**` (chaos/*, engine_lease, engine_wal, health_gate*, lease_monitor*, obligation, ring_buffer, settle_fsm, store_conformance_wal, store_triod, store_wal, unwind_crash, wal_unwind_semantics), `test/fond*/**` (fond_differential, fond_subject, fond/horizon, fond/replay, fond/session_fencing), `test/execution_receipt_test.exs`, `test/state_machine_test.exs`, `test/ash_pplan/htn_test.exs`, `test/hardening/*`, `test/ash_pplan_test.exs`, `test/release_contract_test.exs`, `test/workflow/evidence_subject_escaping_court_test.exs`, `test/support/durable/**`, `test/support/descriptor_fixtures.ex`.

Gate: `MIX_BUILD_ROOT=_build-drain bin/gate` (or `mix test test/durable test/fond*`)

### (b) Doc DoD wave
`docs/**` (diataxis tutorials/how-to/explanation/reference, architecture.md, demonstration.md, POST-ARCHIVE-MAP.md, PACKAGE-BOUNDARY.md, industrial-deliberation PRD), `README.md`, `notes/*.md` (chicago-adoption, ferroplan-fond-verdict, ggen-igniter-feature-audit, graphlaw-engine, graphlaw-wasm-api-survey, ocel-vocabulary-audit, receipt-schema-diff, sa2a-adapter-verdict, twin-handoff-ash-a2a), `ontology.ttl`, `ontology/*.ttl`, `checkpoints/research200-tla-court.txt`, `priv/tla/durable/DurableProtocol.tla`.

Gate: `bin/observe-ontology && bin/gate` (docs-only; ontology gate + full gate).

### (c) POWL / telemetry / playground new namespaces
`lib/ash_pplan/powl.ex`, `powl/{project,verifier}.ex`, `lib/ash_pplan/telemetry/**` (broadcaster, emit, emit/{buffering_emitter,event,noop}, event), `lib/ash_pplan/process_evidence.ex`, `lib/ash_pplan/playground/**` (engine_bridge, hive_simulator, scenario_runner, telemetry_broadcaster), `lib/ash_pplan/reactor/middleware/observation.ex`, `test/powl/**`, `test/telemetry/**`, `test/playground/web/playground_live_court_test.exs`, `test/support/playground/**`, `bin/playground`, `bin/playground_boot.exs`.

Gate: `mix test test/powl test/telemetry test/playground`

### (d) Marketplace-sim / capability / provider fixes
`lib/ash_pplan/capability.ex`, `lib/ash_pplan/capability_pack.ex`, `lib/ash_pplan/sa2a/subject_guard.ex`, `priv/ggen/ash-pplan-{pack,store-conformance-pack,workflow-pack}/ontology.ttl`, `test/support/examples/**` (providers/*, ultracode/steps.ex), `lib/ash_pplan/providers/index.ex`.

Gate: `bin/gate marketplace-sim` (per receipts/gate-marketplace-sim-2026-10-04.md) or `mix test test/support/examples` — coordinator should confirm the court name against `bin/gate`.

### (e) CHANGELOG / version / root
`CHANGELOG.md`, `mix.exs`, `bin/{conform,conform-falsify,gate,ggen-doctor,observe-ontology,receipt}`, `bin/airbus-oracle-boot`, `bin/airbus-oracle-gate`, `receipts/v7-package-boundary-2026-11-07.md` (this session's receipt), `notes/landing-manifest-2026-11-07.md` (this file).

Gate: `bin/gate` + `bin/conform`

### (f) Airbus transpiler / parity corpus (lane A1 — partially landed as eb4260f)
`lib/ash_pplan/airbus/{transpiler,turtle}.ex`, `priv/courts/airbus_parity.receipt`, `priv/courts/airbus_parity/**` (corpus + transpiled + receipts/INDEX.md), `test/courts/airbus_*`, `test/support/airbus_oracle*` (client, provisioner, assertions, airbus_fond_oracle).

Gate: `mix test test/courts/airbus_corpus_parity_test.exs test/courts/airbus_fond_differential_test.exs test/courts/airbus_parity_court_test.exs`

Group overlap warning: files appear in exactly one group above; `test/support/examples` straddles (a)/(d) by content — coordinator may merge (a)+(d) if cleaner.

## Repo 2: /Users/sac/ash_a2a — 35 files touched

### (g) I-wave pplan courts
`lib/mix/tasks/ash_a2a.pplan_courts.ex`, `test/replan/port_ashpplan_conformance_court_test.exs`, `test/ash_a2a/replan/ash_pplan_port_parity_court_test.exs`, `test/execution/pplan_dispatch_durability_test.exs`, `test/ash_a2a_pplan_ocel_evidence_court_test.exs`, `test/execution/task_run_binding_test.exs`, `test/ash_a2a_margin_gate_e2e_test.exs`, `test/telemetry_bridge/pplan_hazard_bridge_test.exs`, `docs/how-to/run-pplan-courts.md`, `receipts/pplan-courts-20261107.md`.

Gate: `mix ash_a2a.pplan_courts`

### (h) twin / strain / attestation / copilot namespaces
lib: `lib/ash_a2a/twin.ex`, `twin/{asset,hazard,lease,operator,partner,server,tony,vince}.ex`, `strain/{bridge,tensor}.ex`, `attestation/{gate,key}.ex`, `copilot/pipeline.ex`, `ingress/channel.ex`, `telemetry_bridge/pplan_hazard.ex`.
test: `test/twin/**` (twin, tony, vince), `test/strain/**`, `test/attestation/attestation_gate_test.exs`, `test/copilot/pipeline_test.exs`, `test/ingress/channel_test.exs`.

Gate: `mix test test/twin test/strain test/attestation test/copilot test/ingress`

### (i) mix.exs toggle + seams doc
`mix.exs`, `docs/explanation/pplan-seams.md`.

Gate: `mix deps.get && mix test test/execution/pplan_dispatch_durability_test.exs`

## Leftovers for cleanup (coordinator owns deletion)

Lane build roots (leases, delete at integration):
- ash_pplan: `_build-bench-f1`, `_build-dem`, `_build-drain`, `_build-jrp`, `_build-laneA13`, `_build-laneA14`, `_build-laneA3`, `_build-laneD5`, `_build-laneF2`, `_build-laneF5`, `_build-laneF7`, `_build-laneT2`, `_build-laneV4`, `_build-laneX1`, `_build-v1`, `_build_playground`, `_build_test` (~8.7 GB total incl. shared `_build` 762M)
- ash_a2a: `_build-check` 822M, `_build-co` 341M, _build-lane-i3 402M, _build-laneA10 796M, _build-laneA11 405M, _build-laneA15 413M, _build-laneA9 707M, _build-laneI7 405M, _build-laneI9 404M, _build-laneV9 810M, _build-laneX2 791M, _build-laneX3 405M, _build-laneX4 405M) (~7.6 GB total)

/tmp scratch observed: `ash_pplan_bench_claims.dets`, `laneX3-check`, `r1_telemetry2.log`, `v9-pplan-courts-receipt.md`.

bin/__pycache__/*.pyc in ash_pplan/bin — build artifact, delete.

## Sequencing proposal

1. Wait for live lanes to drain (wal.ex witnessed changing at 14:21:50 during census).
2. Re-run the elixir syntax scan (command above) — must be 0 fail before staging.
3. Land groups in order (a) → (f) → (c) → (d) → (b) → (e) for ash_pplan; (g) → (h) → (i) for ash_a2a.
4. Delete lane build roots + /tmp scratch + __pycache__ AFTER final gates pass, BEFORE the final integration commit (cleanup is an admitted transition).
