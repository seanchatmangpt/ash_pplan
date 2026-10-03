# Coverage Index — 2026-10-03 (P7)

Re-scan of the POST-ARCHIVE-MAP P7 claim (`docs/POST-ARCHIVE-MAP.md:98`) after the ERRC rename
(`lib/ash_pplan/generated/` → `lib/ash_pplan/catalog/` + `lib/ash_pplan/providers/` + `workflow/capability_catalog.ex`).

## Claim verification: "34 modules"

**Stale.** Re-scan of the current tree (138 `lib/**/*.ex` files):

- **43** modules have a name-matching test file (`test/**/<basename>_test.exs`, recursive)
- **95** modules have no name-matching test file — of these, **92** have an identified covering test (content reference or named court), **3** are UNCOVERED
- The "34" figure does not reproduce under any single rule (recursive basename match = 95; top-level test/ basename match is larger still; no-content-reference-anywhere = 12). It was captured against a pre-rename, smaller tree and should be read as historical.

## Summary

| bucket | count |
|---|---|
| total lib modules | 138 |
| name-matching test file exists | 43 |
| no name-matching test file | 95 |
| — covered via court/content reference | 92 |
| — UNCOVERED | 3 |

UNCOVERED modules (all three also have **zero references anywhere in lib/test/bin** — dead-code candidates, not just test gaps; new tests are a later item, per P7 scope):

- `lib/ash_pplan/fond/consumer.ex` (`AshPPlan.FOND.Consumer`) — dispatch boundary with no caller
- `lib/ash_pplan/reactor/steps/common.ex` (`AshPPlan.Reactor.Steps.Common`) — superseded by `AshPPlan.Providers.Qualify` (same contract), no caller
- `lib/ash_pplan/workflow/method.ex` (`AshPPlan.Workflow.Method`) — struct never constructed; HDDL/DSL paths use plain maps

## Index — modules with no name-matching test (95)

| module | covering test (file:line) |
|---|---|
| `MODULE` | TEST:LINE |
| `lib/ash_pplan/catalog/plan_catalog.ex` | test/ash_pplan_test.exs:23 |
| `lib/ash_pplan/catalog/projection_catalog.ex` | test/release_contract_test.exs:128 |
| `lib/ash_pplan/compiler.ex` | test/semantic_execution_test.exs:4 |
| `lib/ash_pplan/compiler/error.ex` | test/semantic_execution_test.exs:5 |
| `lib/ash_pplan/fond/consumer.ex` | **UNCOVERED** |
| `lib/ash_pplan/fond/counterexample.ex` | test/fond/fond_harden_h4_test.exs:22 |
| `lib/ash_pplan/fond/differential.ex` | test/fond_differential_test.exs:5 |
| `lib/ash_pplan/fond/policy_supervisor.ex` | test/fond_policy_supervisor_test.exs:4 |
| `lib/ash_pplan/fond/policy_supervisor/offers.ex` | test/fond_policy_supervisor_test.exs:4 |
| `lib/ash_pplan/fond/policy_switch.ex` | test/fond/horizon_test.exs:4 |
| `lib/ash_pplan/fond/projection.ex` | test/fond_projection_contract_test.exs:5 |
| `lib/ash_pplan/fond/provider_registry.ex` | test/fond/fond_harden_h4_test.exs:26 |
| `lib/ash_pplan/fond/recovery.ex` | test/fond_trace_recovery_test.exs:5 |
| `lib/ash_pplan/fond/subject.ex` | test/fond_differential_test.exs:44 |
| `lib/ash_pplan/fond/supervision_session.ex` | test/fond/fond_harden_h4_test.exs:27 |
| `lib/ash_pplan/fond/synthesis.ex` | test/fond_hardening_test.exs:4 |
| `lib/ash_pplan/fond/tla.ex` | test/fond_tla_hardening_test.exs:6 |
| `lib/ash_pplan/fond/tla/json.ex` | test/fond_tla_manifest_json_test.exs:5 |
| `lib/ash_pplan/fond/tla/manifest.ex` | test/fond_tla_manifest_json_test.exs:5 |
| `lib/ash_pplan/fond/tla/mutation.ex` | test/chicago_adoption_test.exs:73 |
| `lib/ash_pplan/fond/trace.ex` | test/fond_trace_recovery_test.exs:5 |
| `lib/ash_pplan/manufacture_targets.ex` | test/release_contract_test.exs:200 |
| `lib/ash_pplan/process_evidence/ash_ex4pm.ex` | test/workflow/qualified_fulfillment_ecosystem_test.exs:27 |
| `lib/ash_pplan/process_evidence/event.ex` | test/standing_test.exs:18 |
| `lib/ash_pplan/process_evidence/ex4pm.ex` | test/workflow/process_evidence_court_test.exs:16 |
| `lib/ash_pplan/providers/a2a.ex` | test/courts/providers/a2a_provider_court_test.exs:5 |
| `lib/ash_pplan/providers/domain.ex` | test/workflow/qualified_fulfillment_ecosystem_test.exs:24 |
| `lib/ash_pplan/providers/durability.ex` | test/workflow/durability_court_test.exs:3 |
| `lib/ash_pplan/providers/durable_dispatch.ex` | test/workflow/durable_adapter_test.exs:85 |
| `lib/ash_pplan/providers/event_state.ex` | test/workflow/durable_adapter_test.exs:81 |
| `lib/ash_pplan/providers/file.ex` | test/execution_receipt_test.exs:207 |
| `lib/ash_pplan/providers/index.ex` | test/hardening/providers_action_hardening_test.exs:152 |
| `lib/ash_pplan/providers/network.ex` | test/hardening/capability_policy_hardening_test.exs:198 |
| `lib/ash_pplan/providers/observation.ex` | test/hardening/capability_policy_hardening_test.exs:144 |
| `lib/ash_pplan/providers/process.ex` | test/chicago_adoption_test.exs:106 |
| `lib/ash_pplan/providers/qualify.ex` | test/hardening/providers_action_hardening_test.exs:3 |
| `lib/ash_pplan/providers/remote.ex` | test/workflow/realization_test.exs:7 |
| `lib/ash_pplan/providers/resolver.ex` | test/hardening/capability_policy_hardening_test.exs:13 |
| `lib/ash_pplan/providers/scheduling.ex` | test/workflow/durable_adapter_test.exs:83 |
| `lib/ash_pplan/reactor.ex` | test/reactor_outcome_test.exs:9 |
| `lib/ash_pplan/reactor/adapter.ex` | test/durable/cancel_test.exs:68 |
| `lib/ash_pplan/reactor/adapters/ash_reactor.ex` | test/workflow/reactor_adapters_test.exs:14 (op-resolution court, keys at :23-27) |
| `lib/ash_pplan/reactor/adapters/bb_reactor.ex` | test/workflow/reactor_adapters_test.exs:14 (op-resolution court, keys at :23-27) |
| `lib/ash_pplan/reactor/adapters/durable.ex` | test/ash_pplan_test.exs:25 |
| `lib/ash_pplan/reactor/adapters/local.ex` | test/workflow/runtime_test.exs:32 |
| `lib/ash_pplan/reactor/adapters/reactor_file.ex` | test/workflow/reactor_adapters_test.exs:14 (op-resolution court, keys at :23-27) |
| `lib/ash_pplan/reactor/adapters/reactor_process.ex` | test/workflow/process_availability_court_test.exs:34 |
| `lib/ash_pplan/reactor/adapters/reactor_req.ex` | test/workflow/reactor_adapters_test.exs:14 (op-resolution court, keys at :23-27) |
| `lib/ash_pplan/reactor/durable/checkpointed.ex` | test/durable/run_test.exs:3 |
| `lib/ash_pplan/reactor/durable/child_error.ex` | test/durable/dispatch_test.exs:104 |
| `lib/ash_pplan/reactor/durable/clock.ex` | test/burn_in/ocel_digest_endurance_test.exs:25 |
| `lib/ash_pplan/reactor/durable/key.ex` | test/fond/tla_differential_edge_test.exs:167 |
| `lib/ash_pplan/reactor/durable/middleware.ex` | test/durable/unwind_test.exs:219 |
| `lib/ash_pplan/reactor/durable/records.ex` | test/hardening/dets_read_no_sync_test.exs:188 |
| `lib/ash_pplan/reactor/durable/status.ex` | test/chicago_adoption_test.exs:76 |
| `lib/ash_pplan/reactor/durable/store.ex` | test/execution_receipt_test.exs:90 |
| `lib/ash_pplan/reactor/durable/store/dets.ex` | test/chicago_adoption_test.exs:19 |
| `lib/ash_pplan/reactor/durable/store/ets.ex` | test/chicago_adoption_test.exs:33 |
| `lib/ash_pplan/reactor/middleware/evidence.ex` | test/burn_in/tokyo_mutant_churn_test.exs:367 |
| `lib/ash_pplan/reactor/middleware/identity.ex` | test/durable/unwind_test.exs:8 |
| `lib/ash_pplan/reactor/middleware/observation.ex` | test/hardening/capability_policy_hardening_test.exs:144 |
| `lib/ash_pplan/reactor/step/return_terminals.ex` | test/semantic_execution_test.exs:182 (terminal collection through compiler.ex:331) |
| `lib/ash_pplan/reactor/steps/actuate.ex` | test/workflow/reactor_adapters_test.exs:15 (via local adapter op `actuation_actuate`, lib/ash_pplan/reactor/adapters/local.ex:12) |
| `lib/ash_pplan/reactor/steps/command.ex` | test/workflow/subproject_adapters_test.exs:54 |
| `lib/ash_pplan/reactor/steps/common.ex` | **UNCOVERED** |
| `lib/ash_pplan/reactor/steps/domain_action.ex` | test/workflow/reactor_adapters_test.exs:27 (via ash_reactor `domain_*` ops) |
| `lib/ash_pplan/reactor/steps/propose.ex` | test/stress/sa2a_propose_isolation_test.exs:105 |
| `lib/ash_pplan/reactor/steps/telemetry.ex` | test/hardening/capability_policy_hardening_test.exs:144 |
| `lib/ash_pplan/standing/cached.ex` | test/standing/receipt_cached_test.exs:8 |
| `lib/ash_pplan/standing/chain.ex` | test/standing_test.exs:13 |
| `lib/ash_pplan/standing/ladder.ex` | test/standing_ladder_property_test.exs:3 |
| `lib/ash_pplan/standing/receipt.ex` | test/standing_ladder_property_test.exs:20 |
| `lib/ash_pplan/standing/sj_bridge.ex` | test/standing/sj_bridge_court_test.exs:3 |
| `lib/ash_pplan/state_machine/charts.ex` | test/state_machine_charts_test.exs:42 |
| `lib/ash_pplan/workflow.ex` | test/hardening/capability_policy_hardening_test.exs:14 |
| `lib/ash_pplan/workflow/authority.ex` | test/workflow/authority_metadata_court_test.exs:3 |
| `lib/ash_pplan/workflow/capability_catalog.ex` | test/workflow/workflow_regeneration_court_test.exs:12 (generated projection; also facade_purity_court_test, manufacture_test) |
| `lib/ash_pplan/workflow/dsl/extension.ex` | test/workflow/dsl_verifiers_court_test.exs:7 |
| `lib/ash_pplan/workflow/dsl/info.ex` | test/oban_test.exs:118 |
| `lib/ash_pplan/workflow/dsl/method.ex` | test/workflow/dsl_test.exs:51,143 (method entity + undeclared-task mutation refusal) |
| `lib/ash_pplan/workflow/dsl/task.ex` | test/chicago_adoption_test.exs:246 |
| `lib/ash_pplan/workflow/dsl/transformers/generate_model.ex` | test/workflow/dsl_verifiers_court_test.exs:3 |
| `lib/ash_pplan/workflow/dsl/verifiers/acyclic_dependencies.ex` | test/workflow/dsl_verifiers_court_test.exs:105 |
| `lib/ash_pplan/workflow/dsl/verifiers/capabilities_parse.ex` | test/workflow/dsl_verifiers_court_test.exs:185 |
| `lib/ash_pplan/workflow/dsl/verifiers/helpers.ex` | test/burn_in/tokyo_mutant_churn_test.exs:418 |
| `lib/ash_pplan/workflow/dsl/verifiers/outcome_closure.ex` | test/workflow/dsl_verifiers_court_test.exs:74 |
| `lib/ash_pplan/workflow/dsl/verifiers/unique_ids.ex` | test/workflow/dsl_verifiers_court_test.exs:232 |
| `lib/ash_pplan/workflow/evidence.ex` | test/burn_in/tokyo_mutant_churn_test.exs:367 |
| `lib/ash_pplan/workflow/method.ex` | **UNCOVERED** |
| `lib/ash_pplan/workflow/model.ex` | test/burn_in/ocel_digest_endurance_test.exs:30 |
| `lib/ash_pplan/workflow/project/hddl.ex` | test/hardening/workflow_projection_hardening_test.exs:10 |
| `lib/ash_pplan/workflow/project/p_plan.ex` | test/hardening/workflow_projection_hardening_test.exs:10 |
| `lib/ash_pplan/workflow/project/reactor.ex` | test/semantic_execution_test.exs:14 |
| `lib/ash_pplan/workflow/subject.ex` | test/fond_differential_test.exs:44 |
| `lib/ash_pplan/workflow/task.ex` | test/chicago_adoption_test.exs:246 |

## Index — modules WITH a name-matching test file (43)

| module | test file |
|---|---|
| `lib/ash_pplan.ex` | test/ash_pplan_test.exs |
| `lib/ash_pplan/action/run.ex` | test/durable/run_test.exs |
| `lib/ash_pplan/capability_pack.ex` | test/workflow/capability_pack_test.exs |
| `lib/ash_pplan/capability.ex` | test/sa2a/capability_test.exs |
| `lib/ash_pplan/control_plane.ex` | test/control_plane_test.exs |
| `lib/ash_pplan/execution_receipt.ex` | test/execution_receipt_test.exs |
| `lib/ash_pplan/fond.ex` | test/fond_test.exs |
| `lib/ash_pplan/fond/corpus.ex` | test/fond/corpus_test.exs |
| `lib/ash_pplan/fond/replay.ex` | test/sa2a/replay_test.exs |
| `lib/ash_pplan/frontier_evidence.ex` | test/frontier_evidence_test.exs |
| `lib/ash_pplan/oban.ex` | test/oban_test.exs |
| `lib/ash_pplan/policy_closure/authority_ceiling.ex` | test/policy_closure/authority_ceiling_test.exs |
| `lib/ash_pplan/process_evidence.ex` | test/workflow/process_evidence_test.exs |
| `lib/ash_pplan/provider.ex` | test/sa2a/provider_test.exs |
| `lib/ash_pplan/providers/registry.ex` | test/workflow/registry_test.exs |
| `lib/ash_pplan/reactor_outcome.ex` | test/reactor_outcome_test.exs |
| `lib/ash_pplan/reactor/durable/counterfactual.ex` | test/durable/counterfactual_test.exs |
| `lib/ash_pplan/reactor/durable/engine.ex` | test/durable/engine_test.exs |
| `lib/ash_pplan/reactor/durable/ledger_ocel.ex` | test/durable/ledger_ocel_test.exs |
| `lib/ash_pplan/reactor/durable/migration.ex` | test/durable/migration_test.exs |
| `lib/ash_pplan/reactor/durable/policy_driver.ex` | test/durable/policy_driver_test.exs |
| `lib/ash_pplan/reactor/durable/portable.ex` | test/durable/portable_test.exs |
| `lib/ash_pplan/reactor/durable/run.ex` | test/durable/run_test.exs |
| `lib/ash_pplan/reactor/durable/steps/await.ex` | test/durable/await_test.exs |
| `lib/ash_pplan/reactor/durable/steps/dispatch.ex` | test/durable/dispatch_test.exs |
| `lib/ash_pplan/reactor/durable/steps/poll.ex` | test/durable/poll_test.exs |
| `lib/ash_pplan/reactor/durable/testing.ex` | test/durable/testing_test.exs |
| `lib/ash_pplan/reactor/durable/unwind.ex` | test/durable/unwind_test.exs |
| `lib/ash_pplan/reactor/durable/verifier.ex` | test/durable/verifier_test.exs |
| `lib/ash_pplan/reactor/steps/await.ex` | test/durable/await_test.exs |
| `lib/ash_pplan/realization.ex` | test/workflow/realization_test.exs |
| `lib/ash_pplan/release_receipt.ex` | test/release_receipt_test.exs |
| `lib/ash_pplan/sa2a/capability.ex` | test/sa2a/capability_test.exs |
| `lib/ash_pplan/sa2a/policy_candidate.ex` | test/sa2a/policy_candidate_test.exs |
| `lib/ash_pplan/sa2a/provider.ex` | test/sa2a/provider_test.exs |
| `lib/ash_pplan/sa2a/refusal.ex` | test/sa2a/refusal_test.exs |
| `lib/ash_pplan/sa2a/replay.ex` | test/sa2a/replay_test.exs |
| `lib/ash_pplan/sa2a/subject_guard.ex` | test/sa2a/subject_guard_test.exs |
| `lib/ash_pplan/standing.ex` | test/standing_test.exs |
| `lib/ash_pplan/state_machine.ex` | test/state_machine_test.exs |
| `lib/ash_pplan/workflow/explain.ex` | test/workflow/explain_test.exs |
| `lib/ash_pplan/workflow/project/fond.ex` | test/fond_test.exs |
| `lib/ash_pplan/workflow/runtime.ex` | test/workflow/runtime_test.exs |
