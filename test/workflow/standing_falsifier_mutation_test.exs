defmodule AshPPlan.Workflow.StandingFalsifierMutationTest do
  @moduledoc """
  Anti-vacuity mutation for the standing falsifier court (`test/standing_test.exs`).

  Production property under test: a run whose observed consequence does NOT hold (a named
  post-state check is `false`) is never issued an ALIVE standing receipt — `Standing.receipt/2`
  returns a receipt whose standing field is `REFUSED(observed_consequence_correct)` with the
  `mu_unlawful` broken term.

  Mutation: compile a copy of the production `AshPPlan.Standing` source with the consequence
  layer dropped from the verdict (receipt issued without observed-consequence evidence), under
  the module name `Mutation.Standing`. The falsifier is then run against BOTH modules: the
  production receipt is refused, the mutated receipt is ALIVE — so the court's refusal assertion
  is non-vacuous.

  No mocks: the run evidence is a real evidence map (real `ProcessEvidence.Event` structs, real
  hash-chained `Chain` ledger, real receipt-schema validation); the mutated module is the
  production source with one mechanical break.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.ProcessEvidence.Event
  alias AshPPlan.Standing

  @source_path "lib/ash_pplan/standing.ex"

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)

  @model %{
    tasks: [
      %{id: :admit, depends_on: []},
      %{id: :pay, depends_on: [:admit]},
      %{id: :ship, depends_on: [:pay]}
    ]
  }
  @selection %{admit: :p1, pay: :p2, ship: :p3}
  @gates [%{task: "pay", admit: ["authorized"], successors: ["ship"]}]

  defp event(task, seq, provider, outcome \\ nil) do
    %Event{
      id: "run:r1/#{task}",
      activity: "task_succeeded",
      timestamp: ~U[2026-10-01 00:00:00Z],
      objects: [{"WorkflowRun", "run:r1", "run"}],
      attributes: %{task: task, seq: seq, provider: provider, outcome: outcome},
      subject_id: "subject-1"
    }
  end

  defp run(overrides \\ %{}) do
    Map.merge(
      %{
        run_id: "r1",
        repo: "ash_pplan",
        head: @head,
        base: @base,
        events: [
          event("admit", 1, "p1"),
          event("pay", 2, "p2", "authorized"),
          event("ship", 3, "p3")
        ],
        model: @model,
        selection: @selection,
        fond_gates: @gates,
        execution: {%{pay: 1}, %{pay: 1}},
        consequence: [order_fulfilled: true, one_shipment: false],
        observation: %{shipments: 0}
      },
      overrides
    )
  end

  defp cmds,
    do: [
      %{
        cmd: "mix test test/workflow/standing_falsifier_mutation_test.exs",
        cwd: File.cwd!(),
        exit: 0
      }
    ]

  defp compile_mutated! do
    source = File.read!(Path.join(File.cwd!(), @source_path))

    # Mechanical break: the receipt's verdict drops the observed-consequence layer.
    mutated =
      source
      |> String.replace(
        "defmodule AshPPlan.Standing do",
        "defmodule AshPPlan.Mutation.Standing do"
      )
      |> String.replace(
        "result = verdict(v.plan_correct, v.execution_correct, v.observed_consequence_correct)",
        "result = verdict(v.plan_correct, v.execution_correct, :ok)"
      )

    assert mutated != source, "the mutation needle no longer matches the production source"

    Code.compile_string(mutated)
  end

  test "control: a failing consequence check is refused with the broken term" do
    Code.put_compiler_option(:ignore_module_conflict, true)

    assert Standing.observed_consequence_correct(run()) == {:error, [:one_shipment]}
    assert Standing.standing(run()) == {:lost, [:observed_consequence_correct]}

    assert {:ok, receipt} = Standing.receipt(run(), replay_commands: cmds())
    assert receipt.standing.value == "REFUSED(observed_consequence_correct)"
  end

  test "MUTATION (consequence layer dropped): the same run is issued an ALIVE receipt" do
    Code.put_compiler_option(:ignore_module_conflict, true)
    compile_mutated!()
    mod = AshPPlan.Mutation.Standing

    # the layer judges and the falsifier still fire, but the receipt's verdict ignores them
    assert mod.observed_consequence_correct(run()) == {:error, [:one_shipment]}
    assert mod.standing(run()) == {:lost, [:observed_consequence_correct]}

    assert {:ok, receipt} = mod.receipt(run(), replay_commands: cmds())
    assert receipt.standing.value == "ALIVE", "the mutated receipt must be ALIVE"
  end
end
