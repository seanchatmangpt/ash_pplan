# AshPPlan Mutation & Anti-Vacuity Audit (v26.11.15)

**Audit Date**: 2026-11-16  
**Auditor**: Agent 9 of 20 (`ash_pplan_auditor_mutations`)  
**Target Repository**: `/Users/sac/ash_pplan`  
**Standing**: AUDITED (Defects & Vacuity Gaps Identified)  
**Deliverable**: `/Users/sac/ash_pplan/docs/jira/v26.11.15/02_mutation_audit.md`  

---

## Executive Summary

A comprehensive live audit of the mutation testing, domain model falsifiers, anti-vacuity boundary conditions, and invalid plan rejection machinery in `/Users/sac/ash_pplan` was conducted.

While `ash_pplan` contains sophisticated anti-vacuity mechanisms—such as the 25-counterexample SHACL/ontology refusal harness in `bin/conform-falsify`, in-process Chicago sabotage tests, and 15-mutant store conformance testing—the audit discovered **critical surviving mutants, broken sabotage needles caused by production code refactoring, missing module dependencies, hardcoded external commit pin drift, untested negative TLA controls, vacuous POWL admission bypasses, and an extreme test-tagging vacuum where `mix test --only mutation` excludes 2,751 tests**.

No source or test files in `/Users/sac/ash_pplan` were modified during this audit.

---

## Audit Findings Matrix

| ID | Category | Severity | File / Module | Summary |
|---|---|---|---|---|
| **MUT-01** | Test Tagging / CI | **CRITICAL** | `test/workflow/semantic_reality_runtime_court_test.exs:94` | `mix test --only mutation` runs exactly 1 test; 2,751 tests excluded; dedicated mutation suites untagged |
| **MUT-02** | Mutation Test Breakage | **BLOCKER** | `test/chicago_adoption_test.exs:187-195` | Sabotage needle drifted from `store/dets.ex:279` (`claimable?/3` refactoring); test fails with raised error |
| **MUT-03** | Surviving Mutant | **CRITICAL** | `test/durable/store_conformance_dets_test.exs:300` | Mutant `TakeSignalAdoptRegardless` is NOT killed by law `take_signal_atomic` (anti-vacuity gap) |
| **MUT-04** | Ontology Drift | **HIGH** | `test/durable/store_conformance_dets_test.exs:346` | `{:take_signal, 7}` added to `Store` behaviour but missing from ontology callback declaration |
| **MUT-05** | External Dependency Drift | **HIGH** | `test/courts/pack_gate_witness_court_test.exs:53` | Hardcoded SHA `29c57908...` drifted from `ggen-marketplace` HEAD `4bc81db7...` |
| **MUT-06** | Python Dependency Defect | **HIGH** | `priv/ggen/semantic-gate-witness/generated/semantic_gate_witness_court.py:16` | Missing `tomllib` under ambient Python causes 5 test failures in `pack_gate_witness_court_test.exs` |
| **MUT-07** | Untested Negative Controls | **HIGH** | `lib/ash_pplan/fond/tla/mutation.ex:9-22`, `test/fond_tla_mutation_test.exs:8-22` | 4 of 5 TLA mutants (`:drop_goal_property`, `:weaken_strong_fairness`, etc.) only assert map key existence; never verified against verifier/TLC |
| **MUT-08** | Vacuous Admission Bypass | **CRITICAL** | `lib/ash_pplan/compiler.ex:135`, `lib/ash_pplan/powl.ex:132` | `admit_powl({:error, %{reason: :unsupported_powl_shape}})` returns `:ok`, bypassing validation for malformed POWL |
| **MUT-09** | Gate Mutation Under-sampling | **MEDIUM** | `test/courts/pack_gate_mutation_court_test.exs:29` | Only 3 sampled gates tested out of 234 SPARQL gates in `priv/ggen/` |
| **MUT-10** | Unautomated Manual Mutations | **MEDIUM** | `test/durable/policy_failover_court_test.exs`, `cancel_test.exs`, `unwind_test.exs`, etc. | 16 documented anti-vacuity mutations exist only as docstring comments labeled "(run manually)" |
| **MUT-11** | Asymmetric SHACL Mutations | **LOW** | `bin/conform-falsify:65-119` | 13 ontology counterexamples only test refusal; lack Leg 2 shape-weakening anti-vacuity proofs |

---

## Detailed Findings

### MUT-01: Severe Test-Tagging Vacuum in `mix test --only mutation`

- **Target**: `test/workflow/semantic_reality_runtime_court_test.exs:94`
- **Severity**: **CRITICAL**
- **Description**:
  The task instructions specify executing mutation suites with `mix test --only mutation`.
  Across the entire `ash_pplan` repository (containing 2,752 total tests), exactly **ONE** test is decorated with `@tag :mutation`:
  ```elixir
  # test/workflow/semantic_reality_runtime_court_test.exs:94
  @tag :mutation
  test "mutation: failing task ends in typed :failed, not a raise", %{store: store} do
  ```
  The dedicated mutation suites (`test/durable/mutations/*.exs`, `test/workflow/standing_falsifier_mutation_test.exs`, `test/chicago_adoption_test.exs`, `test/fond_tla_mutation_test.exs`, `test/durable/store_conformance_dets_test.exs`) are **not tagged** with `:mutation`.
  Consequently, executing `mix test --only mutation` excludes 2,751 tests and runs a single test, creating a false impression of repo-wide mutation verification.
- **Exact Command Executed**:
  ```sh
  cd /Users/sac/ash_pplan && mix test --only mutation
  ```
- **Command Output**:
  ```
  Running ExUnit with seed: 38240, max_cases: 32
  Excluding tags: [:test]
  Including tags: [:mutation]

  .
  Finished in 19.1 seconds (18.8s async, 0.3s sync)
  Result: 1 passed, 2751 excluded
  ```

---

### MUT-02: Chicago Sabotage Needle Drift in `Dets` Claim CAS Exclusivity

- **Target**: `test/chicago_adoption_test.exs:187-195` (targeting `lib/ash_pplan/reactor/durable/store/dets.ex:279`)
- **Severity**: **BLOCKER**
- **Description**:
  `AshPPlan.ChicagoAdoptionTest` uses `AshPPlan.Test.Chicago.sabotage_source!/3` to mechanically inject breaks into production source files in-process.
  In `test/chicago_adoption_test.exs:193`:
  ```elixir
  {"        if claimable?(rec, claimer, lookup(st.tab, {:lease, id}, nil), now) do",
   "        if true do"}
  ```
  Production code in `lib/ash_pplan/reactor/durable/store/dets.ex:279` was refactored: the external `{:lease, id}` lookup in `st.tab` was removed, and `claimable?` was changed from a 4-argument function to a 3-argument function:
  ```elixir
  # lib/ash_pplan/reactor/durable/store/dets.ex:279
  if claimable?(rec, claimer, now) do
  ```
  Because the text needle no longer matches, `sabotage_source!` raised an error, preventing the test from running and causing test suite failure. The negative witness for DETS claim compare-and-set exclusivity is completely broken.
- **Exact Command Executed**:
  ```sh
  cd /Users/sac/ash_pplan && MIX_BUILD_ROOT=_build_test mix test test/chicago_adoption_test.exs
  ```
- **Command Output**:
  ```
  1) test dets store persistence negative witnesses claim exclusivity holds; a store with the claim CAS stripped is detected (AshPPlan.ChicagoAdoptionTest)
     test/chicago_adoption_test.exs:187
     sabotage needle no longer matches lib/ash_pplan/reactor/durable/store/dets.ex: "        if claimable?(rec, claimer, lookup(st.tab, {:lease, id}, nil), now) do"
     code: sabotage_source!(dets_source, "AshPPlan.Reactor.Durable.Mutation.Chicago.StoreDets", [
     stacktrace:
       (ash_pplan 26.11.10) test/support/chicago/chicago.ex:43: anonymous fn/3 in AshPPlan.Test.Chicago.sabotage_source!/3
       (elixir 1.20.4) lib/enum.ex:2622: Enum."-reduce/3-lists^foldl/2-0-"/3
       (ash_pplan 26.11.10) test/support/chicago/chicago.ex:42: AshPPlan.Test.Chicago.sabotage_source!/3
       test/chicago_adoption_test.exs:191: (test)

  2) test ggen regeneration drift court negative witness the court's byte comparison fires on a genuinely hand-edited template (AshPPlan.ChicagoAdoptionTest)
     test/chicago_adoption_test.exs:214
     ** (RuntimeError) ggen_igniter: reactor reconciliation failed (refused): %UndefinedFunctionError{module: GgenIgniter.Native.GraphNif, function: :query_turtle, arity: 2, reason: nil, message: nil}

  Finished in 1.9 seconds (0.00s async, 1.9s sync)
  Result: 3/5 passed, Failed: 2 tests
  ```

---

### MUT-03: Surviving Mutant `TakeSignalAdoptRegardless` in Store Conformance

- **Target**: `test/durable/store_conformance_dets_test.exs:252-270, 300-307`
- **Severity**: **CRITICAL**
- **Description**:
  In `AshPPlan.Reactor.Durable.StoreConformanceAntiVacuityTest`, 15 hand-written mutants are evaluated against the generated store conformance laws.
  Mutant `TakeSignalAdoptRegardless` defines an "adopt-regardless" divergence: when strict take answers `:none`, it returns the standing checkpoint anyway:
  ```elixir
  defmodule TakeSignalAdoptRegardless do
    use Mutant
    def take_signal(s, id, name, key, label, meta, now) do
      case Ets.take_signal(s, id, name, key, label, meta, now) do
        :none ->
          case Enum.find(Ets.standing(s, id), &(&1.step_key == key)) do
            nil -> :none
            cp -> {:ok, cp}
          end
        other -> other
      end
    end
  end
  ```
  The test asserts:
  ```elixir
  @mutants [
    {TakeSignalAdoptRegardless, ["take_signal_atomic"]},
    ...
  ]
  ```
  During live execution, `failed(TakeSignalAdoptRegardless)` returned `[]`. Law `take_signal_atomic` failed to detect the mutant!
  The mutant survived, witnessing an anti-vacuity flaw in the `take_signal_atomic` conformance law.
- **Exact Command Executed**:
  ```sh
  cd /Users/sac/ash_pplan && MIX_BUILD_ROOT=_build_test mix test test/durable/store_conformance_dets_test.exs
  ```
- **Command Output**:
  ```
  2) test mutant AshPPlan.Reactor.Durable.StoreConformanceAntiVacuityTest.TakeSignalAdoptRegardless fails ["take_signal_atomic"] (AshPPlan.Reactor.Durable.StoreConformanceAntiVacuityTest)
     test/durable/store_conformance_dets_test.exs:300
     AshPPlan.Reactor.Durable.StoreConformanceAntiVacuityTest.TakeSignalAdoptRegardless was not caught by law take_signal_atomic: []
     code: for id <- unquote(expected) do
     stacktrace:
       (elixir 1.20.4) lib/enum.ex:1725: Enum."-map/2-lists^map/1-1-"/2
       test/durable/store_conformance_dets_test.exs:303: (test)
  ```

---

### MUT-04: Ontology vs Store Behaviour Callback Drift (`{:take_signal, 7}`)

- **Target**: `test/durable/store_conformance_dets_test.exs:346-353`
- **Severity**: **HIGH**
- **Description**:
  `StoreConformanceAntiVacuityTest` asserts that the callbacks declared in the ontology (`Conf.callbacks()`) equal the callbacks declared on `AshPPlan.Reactor.Durable.Store` behaviour:
  ```elixir
  test "ontology callbacks equal the Store behaviour's callbacks" do
    declared = Enum.sort(Conf.callbacks())
    real = Enum.sort(Store.behaviour_info(:callbacks) -- Store.behaviour_info(:optional_callbacks))
    assert declared == real
  end
  ```
  Live execution shows `Store` behaviour has 22 callbacks, including `{:take_signal, 7}`, but `Conf.callbacks()` from the ontology only declares 21 callbacks (`take_signal` is missing).
  The ontology has drifted from the production Store behaviour contract.
- **Exact Command Executed**:
  ```sh
  cd /Users/sac/ash_pplan && MIX_BUILD_ROOT=_build_test mix test test/durable/store_conformance_dets_test.exs
  ```
- **Command Output**:
  ```
  1) test ontology callbacks equal the Store behaviour's callbacks (AshPPlan.Reactor.Durable.StoreConformanceAntiVacuityTest)
     test/durable/store_conformance_dets_test.exs:346
     Assertion with == failed
     code:  assert declared == real
     left:  [checkpoints: 2, claim: 5, claim_undo: 4, consume_signal: 3, deliver_signal: 4, get_run: 2, get_waiter: 3, list_runs: 1, mark_undone: 4, park: 6, pending_signal: 3, record: 6, release: 3, release_all: 2, release_claim: 3, release_undo: 3, signals: 2, standing: 2, start_run: 2, transition: 5, waiters: 2]
     right: [{:checkpoints, 2}, {:claim, 5}, {:claim_undo, 4}, {:consume_signal, 3}, {:deliver_signal, 4}, {:get_run, 2}, {:get_waiter, 3}, {:list_runs, 1}, {:mark_undone, 4}, {:park, 6}, {:pending_signal, 3}, {:record, 6}, {:release, 3}, {:release_all, 2}, {:release_claim, 3}, {:release_undo, 3}, {:signals, 2}, {:standing, 2}, {:start_run, 2}, {:take_signal, 7}, {:transition, 5}, {:waiters, 2}]
     stacktrace:
       test/durable/store_conformance_dets_test.exs:352: (test)
  ```

---

### MUT-05: Pinned Git SHA Drift in Pack Gate Witness Court

- **Target**: `test/courts/pack_gate_witness_court_test.exs:35, 53-56`
- **Severity**: **HIGH**
- **Description**:
  In `test/courts/pack_gate_witness_court_test.exs`, the court verifies that the vendored pack matches the marketplace git commit:
  ```elixir
  @pinned_marketplace_sha "29c579082aefe57eda5695d13cd4edb76cb82b31"

  test "vendored pack is locked at the pinned marketplace sha" do
    {out, 0} = System.cmd("git", ["-C", "/Users/sac/ggen-marketplace", "rev-parse", "HEAD"])
    assert String.trim(out) == @pinned_marketplace_sha
  ```
  The commit in `/Users/sac/ggen-marketplace` is currently `4bc81db7cfc82743c154635972c9474b2bede03e`.
  The hardcoded SHA pin in `ash_pplan` drifted, causing the test to fail.
- **Exact Command Executed**:
  ```sh
  cd /Users/sac/ash_pplan && MIX_BUILD_ROOT=_build_test mix test test/courts/pack_gate_witness_court_test.exs --no-compile
  ```
- **Command Output**:
  ```
  4) test vendored pack is locked at the pinned marketplace sha (AshPPlan.Courts.PackGateWitnessCourtTest)
     test/courts/pack_gate_witness_court_test.exs:53
     Assertion with == failed
     code:  assert String.trim(out) == @pinned_marketplace_sha
     left:  "4bc81db7cfc82743c154635972c9474b2bede03e"
     right: "29c579082aefe57eda5695d13cd4edb76cb82b31"
     stacktrace:
       test/courts/pack_gate_witness_court_test.exs:55: (test)
  ```

---

### MUT-06: Python Script Failure (`tomllib` Missing) in Semantic Gate Witness Court

- **Target**: `priv/ggen/semantic-gate-witness/generated/semantic_gate_witness_court.py:16`
- **Severity**: **HIGH**
- **Description**:
  `AshPPlan.Courts.PackGateWitnessCourtTest` executes `python3 generated/semantic_gate_witness_court.py`.
  Line 16 of the script executes:
  ```python
  import tomllib
  ```
  `tomllib` was introduced in standard library in Python 3.11. In environments where `python3` resolves to Python 3.10 or an unconfigured Python environment without `tomllib`, the script crashes with `ModuleNotFoundError: No module named 'tomllib'`.
  This causes 5 out of 7 tests in `PackGateWitnessCourtTest` to fail with empty output or JSON decode errors.
- **Exact Command Executed**:
  ```sh
  cd /Users/sac/ash_pplan && MIX_BUILD_ROOT=_build_test mix test test/courts/pack_gate_witness_court_test.exs --no-compile
  ```
- **Command Output**:
  ```
  Traceback (most recent call last):
    File "/Users/sac/ash_pplan/priv/ggen/semantic-gate-witness/generated/semantic_gate_witness_court.py", line 16, in <module>
      import tomllib
  ModuleNotFoundError: No module named 'tomllib'
  ...
  Result: 1/7 passed, Failed: 6 tests
  ```

---

### MUT-07: Unverified Negative TLA Mutants in `AshPPlan.FOND.TLA.Mutation`

- **Target**: `lib/ash_pplan/fond/tla/mutation.ex:9-22`, `test/fond_tla_mutation_test.exs:8-22`
- **Severity**: **HIGH**
- **Description**:
  `AshPPlan.FOND.TLA.Mutation.suite/1` generates 5 negative mutants:
  1. `:drop_goal_property` (removes `PROPERTY GoalReached`)
  2. `:weaken_strong_fairness` (replaces `SF_vars` with `WF_vars`)
  3. `:stutter_first_tick` (alters tick step)
  4. `:drop_first_branch` (drops branch definition)
  5. `:undefined_next_action` (injects undefined action `A_999999`)

  In `test/fond_tla_mutation_test.exs`:
  - Test 1 (`"mutation suite manufactures independent negative controls"`) merely checks `Keyword.has_key?/2` for all 5 mutant keys.
  - Test 2 (`"dropping an admitted branch is rejected by the independent reader"`) verifies that `:drop_first_branch` raises when checked by `TLAReader.check!/1`.
  - The remaining 4 mutants (`:drop_goal_property`, `:weaken_strong_fairness`, `:stutter_first_tick`, `:undefined_next_action`) are **never fed to a parser, checker, or TLC model checker**. There is zero test evidence proving that these 4 negative mutants are actually rejected! A mutant that is never asserted to fail is a vacuous negative control.
- **Exact Command Executed**:
  ```sh
  cd /Users/sac/ash_pplan && MIX_BUILD_ROOT=_build_test mix test test/fond_tla_mutation_test.exs --no-compile
  ```
- **Command Output**:
  ```
  Running ExUnit with seed: 280278, max_cases: 32

  ..
  Finished in 0.03 seconds (0.03s async, 0.00s sync)
  Result: 2 passed
  ```

---

### MUT-08: Vacuous POWL Admissibility Bypass in `AshPPlan.Compiler`

- **Target**: `lib/ash_pplan/compiler.ex:135`, `lib/ash_pplan/powl.ex:132`
- **Severity**: **CRITICAL**
- **Description**:
  In `lib/ash_pplan/compiler.ex`, `compile_spec/2` calls `validate_powl/1`:
  ```elixir
  defp validate_powl(%{formalism: :powl} = plan) do
    plan |> POWL.normalize() |> admit_powl()
  end
  ```
  `POWL.normalize/1` handles valid POWL structures, but for invalid shapes:
  ```elixir
  # lib/ash_pplan/powl.ex:132
  def normalize(_other), do: {:error, %{reason: :unsupported_powl_shape}}
  ```
  In `lib/ash_pplan/compiler.ex:135`:
  ```elixir
  defp admit_powl({:error, %{reason: :unsupported_powl_shape}}), do: :ok
  ```
  If a candidate explicitly declares `formalism: :powl`, but provides a completely malformed or unsupported POWL payload, `admit_powl` catches `{:error, %{reason: :unsupported_powl_shape}}` and answers `:ok`!
  This creates a vacuous bypass: instead of rejecting an un-normalizable POWL candidate fail-closed, the compiler treats it as valid and bypasses separability verification.

---

### MUT-09: SPARQL Pack Gate Mutation Under-sampling

- **Target**: `test/courts/pack_gate_mutation_court_test.exs:29-53`
- **Severity**: **MEDIUM**
- **Description**:
  There are **234 SPARQL gate files (`*.rq`)** located across packs in `priv/ggen/`.
  `PackGateMutationCourtTest` explicitly notes:
  > *"The ERRC synthesis found no gate in the tree carries a NEGATIVE witness: conform-falsify covers the SHACL profile only. This court closes the remaining hole by proving each sampled gate's WHERE clause actually depends on the data it inspects..."*
  However, `PackGateMutationCourtTest` only tests **3 sampled gates**:
  1. `ash-pplan-pack/010_projections.rq`
  2. `ash-pplan-runtime-overlay/06-receipt.rq`
  3. `ash-pplan-standing-pack/030_standings.rq`
  The remaining 231 gates (98.7% of all SPARQL gates in `priv/ggen/`) are never tested with mutation sensitivity (deleting their discriminating pattern to assert that the gate rows drop to zero).
- **Exact Command Executed**:
  ```sh
  find /Users/sac/ash_pplan/priv/ggen -name "*.rq" | wc -l
  # Output: 234
  cd /Users/sac/ash_pplan && MIX_BUILD_ROOT=_build_test mix test test/courts/pack_gate_mutation_court_test.exs --no-compile
  # Output: 4 passed
  ```

---

### MUT-10: 16 Documented Anti-Vacuity Mutations Unautomated ("Run Manually")

- **Target**: `test/durable/*.exs`
- **Severity**: **MEDIUM**
- **Description**:
  Multiple durable engine test suites document specific anti-vacuity mutations in their module docstrings, but mark them as `(run manually)` without an automated executable test file (unlike `test/durable/mutations/*.exs`).
  Specifically:
  1. `test/durable/policy_failover_court_test.exs:13-17`:
     - Skip `observe/4` (outside-domain court completes instead of refusing)
     - Stop recording decisions (replay court sees second provider call)
     - Drop fingerprint comparison in `replay_decision/4` (divergence court completes)
     - Ignore step limit (limit court completes/loops instead of refusing)
  2. `test/durable/cancel_test.exs:12-16`:
     - Skip `:cancelling` transition in `Engine.cancel/3`
     - Remove `claim_undo` in `Unwind`
     - Widen settle `from` lists in `Engine` to include `:cancelling`
  3. `test/durable/unwind_test.exs:6-8`:
     - Drop `Enum.sort_by(& &1.seq, :desc)` in `Unwind`
     - Drop `claim_undo`
     - Drop identity seeding
  4. `test/durable/extra_await_test.exs:11-14`:
     - Recompute deadline in `Await.park/7`
     - Skip `mod.release/3` in `Poll`
  5. `test/durable/extra_claim_test.exs:10-13`:
     - Make `Ets.claim/5` treat a nil claimer as re-entrant
     - Drop claim call in `Engine.claim_and_run/4`
  6. `test/durable/tla_trace_test.exs:16-19`:
     - Remove terminal-absorbing clause in `check/2`
     - Remove holder check in `:claim`
  7. `test/durable/dispatch_durability_test.exs:14`:
     - Anti-vacuity falsifier (mutation, run manually)

  These 16 documented mutations are currently manual thought experiments with zero continuous test verification.

---

### MUT-11: Asymmetric SHACL Mutations in `bin/conform-falsify`

- **Target**: `bin/conform-falsify:65-119, 129-262`
- **Severity**: **LOW**
- **Description**:
  `bin/conform-falsify` executes 25 counterexamples against `ggen law validate`.
  12 of them (`SHAPE_MUTATIONS`) follow the strict 2-leg non-vacuity protocol:
  - Leg 1: Canonical shape REFUSES the counterexample.
  - Leg 2: Weakened shape ADMITS the counterexample (proving refusal was caused by the exact clause under test).
  The other 13 (`MUTATIONS`) only implement Leg 1 (refusal). If `ggen law validate` were to fail for an unrelated reason (e.g. malformed syntax in the counterexample), Leg 1 would pass vacuously.
  Furthermore, `SHAPE_MUTATIONS` only covers 3 shapes (`WorkflowShape`, `TaskShape`, `CapabilityPackShape`), leaving `PlanShape`, `StepShape`, `VariableShape`, and `ProjectionShape` without 2-leg weakening proofs.
- **Exact Command Executed**:
  ```sh
  cd /Users/sac/ash_pplan && ./bin/conform-falsify
  ```
- **Command Output**:
  ```
  refused: unadmitted projection standing
  refused: duplicate projection order
  refused: duplicate projection source term
  refused: step preceded by a step of another plan
  refused: step preceded by itself
  refused: step preceded by something that is not a step
  refused: plan without a label
  refused: plan with no steps
  refused: step with two labels
  refused: projection source term that is a literal
  refused: step using a variable from another plan
  refused: step outside any plan
  refused: variable outside any plan
  refused + flips under weakening: workflow without a workflowName
  refused + flips under weakening: workflow with two workflowNames
  refused + flips under weakening: workflow without a goal
  refused + flips under weakening: workflow with two goals
  refused + flips under weakening: workflow with no tasks
  refused + flips under weakening: workflow hasTask pointing at a non-Task
  refused + flips under weakening: task without a taskId
  refused + flips under weakening: task with two taskIds
  refused + flips under weakening: task authority ceiling "do"
  refused + flips under weakening: task authority ceiling "plan"
  refused + flips under weakening: CapabilityPack ceiling "plan"
  refused + flips under weakening: CapabilityPack with two authorityCeilings

  25 counterexamples refused by the ggen.toml [law] profile (12 of them proven non-vacuous by shape weakening)
  ```

---

## Verifiably Sound Mutation & Falsifier Surfaces

The following mutation and falsifier suites were executed live and verified to be genuinely sound and non-vacuous:

1. **Durable Engine Mutations** (`test/durable/mutations/`):
   - `counterfactual_digest_mutation_test.exs`: Replay against original store mutates ledger (control passed, mutant detected).
   - `migration_orphan_mutation_test.exs`: Orphan refusal removed admits orphans (control refused, mutant detected).
   - `policy_driver_admit_mutation_test.exs`: Unconditional driver admission waves through inadmissible driver (control refused, mutant detected).
   - *Status*: 6/6 passed in 1.5s.
2. **Standing Falsifier Mutation** (`test/workflow/standing_falsifier_mutation_test.exs`):
   - Consequence layer dropped from receipt verdict (control refused `mu_unlawful`, mutant issued `ALIVE` receipt, detected).
   - *Status*: 2/2 passed in 0.3s.
3. **Compiler Fail-Closed Refusals** (`test/compiler_refusal_test.exs`):
   - 14 distinct refusal reasons verified (unknown plan, empty plan, duplicate steps, invalid handlers, terminal limit > 16, improper lists, non-binary arguments).
   - *Status*: 14/14 passed in 0.5s.
4. **HTN & STRIPS Anti-Vacuity Falsifiers** (`test/ash_pplan/htn_test.exs`):
   - Precondition removal on method `:verify_nh3_serial` forces planning failure.
   - Unreachable goal in STRIPS state-space planner fails with `:no_plan_found`.
   - Missing precondition `:tenant_active` on method `:m_full_dispatch` fails with `:no_applicable_method`.
   - *Status*: 13/13 passed in 0.4s.
5. **POWL Reachability & Deadlock Falsifiers** (`test/powl/reachability_court_test.exs`):
   - Unsound loop-with-choice model simulates to deadlock (`verdict.outcome == :deadlock`) and is refused (`{:error, :loop_choice_body}`).
   - *Status*: 3/3 passed in 0.04s.
6. **Case Study Numbers Corruption Court** (`test/case_studies/case_study_numbers_test.exs`):
   - Real number token in `docs/case-studies/*.md` mutated to `"999777333"`; court fails with `"not found verbatim"`.
   - *Status*: 3/3 passed in 4.0s.

---

## Actionable Remediation Plan

1. **Tag All Mutation Courts** (`MUT-01`):
   Add `@moduletag :mutation` to:
   - `test/durable/mutations/counterfactual_digest_mutation_test.exs`
   - `test/durable/mutations/migration_orphan_mutation_test.exs`
   - `test/durable/mutations/policy_driver_admit_mutation_test.exs`
   - `test/workflow/standing_falsifier_mutation_test.exs`
   - `test/chicago_adoption_test.exs`
   - `test/fond_tla_mutation_test.exs`
   - `test/durable/store_conformance_dets_test.exs`
   - `test/courts/pack_gate_mutation_court_test.exs`
   - `test/case_studies/case_study_numbers_test.exs`
2. **Repair Chicago Dets Sabotage Needle** (`MUT-02`):
   Update `test/chicago_adoption_test.exs:193` from:
   `{"        if claimable?(rec, claimer, lookup(st.tab, {:lease, id}, nil), now) do",`
   to:
   `{"        if claimable?(rec, claimer, now) do",`
3. **Fix `take_signal_atomic` Law to Kill `TakeSignalAdoptRegardless`** (`MUT-03`):
   Strengthen `take_signal_atomic` law in `AshPPlan.Test.StoreConformance` so that asserting on an unconsumed or invalid signal strictly detects if an existing standing checkpoint was returned.
4. **Update Ontology Callbacks for Store Behaviour** (`MUT-04`):
   Add `{:take_signal, 7}` to the ontology Store callback declaration so `declared == real`.
5. **Uncouple Marketplace SHA Pin** (`MUT-05`):
   In `test/courts/pack_gate_witness_court_test.exs:53`, read the expected commit from `priv/ggen/vendor/PACKS.lock.json` (`lock["source_git_sha"]`) dynamically or update the pinned SHA.
6. **Ensure Python Environment Carries `tomllib`** (`MUT-06`):
   Add fallback `try: import tomllib except ImportError: import tomli as tomllib` in `priv/ggen/semantic-gate-witness/generated/semantic_gate_witness_court.py`.
7. **Complete TLA Negative Control Assertions** (`MUT-07`):
   Extend `test/fond_tla_mutation_test.exs` to verify that `:drop_goal_property`, `:weaken_strong_fairness`, `:stutter_first_tick`, and `:undefined_next_action` are rejected by `TLAReader.check!` or TLC.
8. **Close POWL Admission Bypass** (`MUT-08`):
   In `lib/ash_pplan/compiler.ex:135`, change:
   `defp admit_powl({:error, %{reason: :unsupported_powl_shape}}), do: :ok`
   to:
   `defp admit_powl({:error, %{reason: :unsupported_powl_shape}}), do: {:error, error(:unsupported_powl_shape, %{})}`
   when `formalism: :powl` is explicitly declared.
9. **Automate Documented Manual Mutations** (`MUT-10`):
   Port the 16 docstring mutations in `cancel_test.exs`, `unwind_test.exs`, `extra_await_test.exs`, etc., into `test/durable/mutations/` using the Chicago `sabotage_source!` pattern.
