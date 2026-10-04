defmodule AshPPlan.Workflow.SemanticRealityRuntimeCourtTest do
  @moduledoc """
  Court pinning the README Quickstart table row semantics to real behavior.

  Row under test: `p-plan:Plan` -> Reactor definition, `p-plan:Step` -> Ash.Reactor step
  binding, `p-plan:Variable` -> Reactor input/argument/result, `P-PLAN precedence -> Reactor
  result dependencies` (contract item 6), observed through `AshPPlan.Workflow.Runtime.run/
  signal-free resume` over `AshPPlan.Reactor.Durable.Store.Ets`.

  Flow follows the README quickstart exactly: a workflow with a human-release gate
  (`Human.Approve`) spliced between select and execute, started on the reference ETS store,
  parked (`:halted`), then signaled and resumed to `:succeeded`.

  Chicago style: real Reactor, real ETS ledger, real generated providers — no mocks, assert on
  final state.

  Anti-vacuity mutation: the same workflow run with a failing `Agent.Execute` provider
  (`Steps.Flaky`) must end in a typed `:failed` observation (`observation.failed_task`), not a
  raise — deleting the durable engine's failure capture would fail this court.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Examples.UltraCode.Steps
  alias AshPPlan.Providers.DurableGate
  alias AshPPlan.Reactor.Durable.{Engine, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Workflow.Runtime

  @frontier [
    %{id: :a, status: :open, deps: []},
    %{id: :b, status: :open, deps: [:a]}
  ]

  setup do
    {:ok, store} = Ets.start_link()
    {:ok, store: store}
  end

  # The README quickstart workflow: UltraCode with a human-release gate between
  # select and execute.
  defp gated_workflow do
    base = Steps.workflow()

    tasks =
      Enum.map(base[:tasks], fn t ->
        if t[:id] == :execute, do: Keyword.put(t, :after, [:select, :gate]), else: t
      end)

    gate = [id: :gate, capability: "Human.Approve", after: [:select], authority: :observe]
    Keyword.put(base, :tasks, List.insert_at(tasks, 2, gate))
  end

  test "quickstart: parks halted on the gate, resumes to succeeded, tape in p-plan step order, receipt digest",
       %{store: store} do
    workflow = gated_workflow()
    providers = [Steps.Local, DurableGate]

    # 2. start a run on the reference store; it parks on the human-release await
    assert {:ok, run} =
             Runtime.run(workflow, %{frontier: @frontier},
               providers: providers,
               store: store,
               run_id: "src-quickstart-1"
             )

    # parked state is :halted on the await
    assert run.observation.state == :halted

    # 3. signal the release and resume; recorded steps are replayed, not re-executed
    assert [wait] = Testing.waiting_on(store, "src-quickstart-1")
    assert {:ok, done} = Runtime.resume(run, signal: {wait, %{released: true}})

    # resume with the signal completes with :succeeded
    assert done.observation.state == :succeeded
    assert {:ok, %{verified: true}} = done.outcome

    # 4. the checkpoint tape reflects p-plan:Step order: precedence = dependency order
    tape = Testing.tape(store, "src-quickstart-1")
    step_label = &inspect("urn:ash-pplan:workflow:ultracode#step-#{&1}")

    assert tape == Enum.map([:observe, :select, :gate, :execute, :integrate, :verify], step_label)

    # execution receipt exists with a non-nil outcome_digest
    assert %AshPPlan.ExecutionReceipt{outcome_digest: digest} = done.evidence.receipt
    assert is_binary(digest) and digest != ""
    assert String.length(digest) == 64

    # the ledger agrees with the observation: completed, no waiter left standing
    assert %{status: :completed} = Engine.fetch(store, "src-quickstart-1")
    assert Testing.waiting_on(store, "src-quickstart-1") == []
  end

  @tag :mutation
  test "mutation: failing task ends in typed :failed, not a raise", %{store: store} do
    workflow = gated_workflow()
    providers = [Steps.Flaky, Steps.Local, DurableGate]

    assert {:ok, run} =
             Runtime.run(workflow, %{frontier: @frontier},
               providers: providers,
               store: store,
               run_id: "src-mutation-1"
             )

    assert run.observation.state == :halted
    assert [wait] = Testing.waiting_on(store, "src-mutation-1")

    # this must return a typed result, never raise
    assert {:ok, failed} = Runtime.resume(run, signal: {wait, %{released: true}})
    assert failed.observation.state == :failed
    assert failed.observation.failed_task == :execute

    # typed error carried on the durable ledger, not a raised exception
    assert %{status: :failed} = Engine.fetch(store, "src-mutation-1")
    assert {:ok, explain} = Runtime.explain(failed)
    assert %{failure: %{sealed: Steps.Flaky}} = explain
  end
end
