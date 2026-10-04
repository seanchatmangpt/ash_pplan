defmodule AshPPlan.Workflow.SemanticRealityAuthorityCourtTest do
  @moduledoc """
  Semantic Reality Authority Court. Pins the authority doctrine end-to-end:

  - the ceiling is `:construct` — nothing in this library grants `:do`;
  - availability is not authority — the `event_state` provider qualifies the
    `Actuation.Actuate` capability, but qualification grants no execution;
  - the `Actuate` step is TOTAL: for any arguments whatsoever it constructs an
    intent descriptor and returns `executed?: false`, `authority: :construct`.
    Execution of the intent needs a lease outside this library.

  Chicago style: real Reactor, real generated provider, real ETS ledger —
  no mocks. Anti-vacuity: an over-privileged arguments map (forged `executed?`,
  forged `authority`, forged lease) is fed to the step and the result shape
  STILL does not execute.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Providers.EventState
  alias AshPPlan.Reactor.Adapters.Local
  alias AshPPlan.Reactor.Durable.{Engine, Store.Ets}
  alias AshPPlan.Reactor.Steps.Actuate
  alias AshPPlan.{Realization, Workflow.Model}
  alias AshPPlan.Workflow.Project.Reactor, as: Proj
  alias AshPPlan.Workflow.Runtime

  @adapters %{local: Local}

  # ---------------------------------------------------------------- step level

  test "actuate step run directly is total: executed? false, authority :construct" do
    assert {:ok, result} = Actuate.run(%{payload: 1}, %{}, name: :pin_intent)
    assert result.executed? == false
    assert result.authority == :construct
    assert result.intent == :pin_intent
  end

  test "anti-vacuity: an over-privileged arguments map cannot make the step execute" do
    poisoned = %{
      executed?: true,
      authority: :do,
      standing: :admitted,
      lease: %{granted_by: "self", token: "forged"},
      do: fn -> raise "must never run" end
    }

    assert {:ok, result} = Actuate.run(poisoned, %{}, name: :poisoned)
    # The forged fields are carried as opaque intent arguments, never lifted
    # into the result shape.
    assert result.executed? == false
    assert result.authority == :construct
    assert result.arguments == poisoned
    # The forged closure is carried inert, never invoked by the step.
    assert is_function(result.arguments.do, 0)
  end

  # ------------------------------------------------------- real Reactor module

  defp actuate_model(tasks) do
    {:ok, m} =
      Model.new(
        name: :actuate_wf,
        tasks: Enum.map(tasks, &Keyword.put(&1, :capability, "Actuation.Actuate"))
      )

    m
  end

  defp bind(m, extra \\ []) do
    Map.new(m.tasks, fn task ->
      {task.id,
       %Realization{
         capability: "Actuation.Actuate",
         provider: :event_state,
         binding: %{adapter: :local, op: :actuation_actuate},
         options: [name: task.id] ++ extra
       }}
    end)
  end

  test "running the Actuate step through a real Reactor module returns an unexecuted intent" do
    m = actuate_model([[id: :intent_a]])
    assert {:ok, reactor} = Proj.project(m, bind(m), adapters: @adapters)
    assert {:ok, result} = Reactor.run(reactor, %{input: 1}, %{}, async?: true)

    assert result.executed? == false
    assert result.authority == :construct
  end

  test "ceiling: the model admits at :construct and grants no authority" do
    m = actuate_model([[id: :a], [id: :b, depends_on: [:a]]])
    assert {:ok, :construct} = AshPPlan.Workflow.Authority.admit(m)
    assert AshPPlan.Workflow.Authority.granted(m) == []
  end

  test "availability is not authority: event_state qualifies Actuation.Actuate but grants nothing" do
    m = actuate_model([[id: :a]])
    ctx = %{ceiling: :construct}

    assert {:ok, realization} =
             EventState.realize(
               %{
                 capability: "Actuation.Actuate",
                 properties: [],
                 evidence: [],
                 authority: :construct,
                 options: []
               },
               ctx
             )

    assert realization.provider == :event_state
    assert realization.binding == %{adapter: :local, op: :actuation_actuate}
    # Qualification realized a binding; it still granted no authority.
    assert {:ok, reactor} = Proj.project(m, %{a: realization}, adapters: @adapters)
    assert {:ok, result} = Reactor.run(reactor, %{input: 1}, %{}, async?: true)
    assert result.executed? == false
  end

  # ------------------------------------------------------------ full workflow

  test "full workflow run containing an actuate task leaves no executed side effect in the ledger" do
    {:ok, store} = Ets.start_link()

    m = actuate_model([[id: :sense], [id: :act, depends_on: [:sense]]])

    assert {:ok, state} =
             Runtime.run(m, %{},
               providers: [EventState],
               store: store,
               run_id: "sra-court-1"
             )

    assert state.observation.state == :succeeded

    recorded =
      store
      |> Engine.steps("sra-court-1")
      |> Map.new(&{to_string(&1.label), &1.output})

    # Every recorded step output is an unexecuted intent: nothing executed.
    assert recorded |> Map.values() |> Enum.all?(&(&1.executed? == false)),
           "a step in the ledger claims execution: #{inspect(recorded)}"

    act_key =
      Enum.find(Map.keys(recorded), &String.contains?(&1, "#step-act"))

    assert is_binary(act_key), "actuate step not found in ledger: #{inspect(Map.keys(recorded))}"
    assert recorded[act_key].authority == :construct
  end

  test "in-process full run (no store) likewise returns only unexecuted intents" do
    m = actuate_model([[id: :act]])

    assert {:ok, state} = Runtime.run(m, %{}, providers: [EventState])
    assert state.observation.state == :succeeded
    assert {:ok, %{executed?: false, authority: :construct}} = state.outcome
  end

  test "anti-vacuity: poisoned inputs through the full run still never execute" do
    {:ok, store} = Ets.start_link()

    m = actuate_model([[id: :act]])

    assert {:ok, state} =
             Runtime.run(m, %{executed?: true, authority: :do},
               providers: [EventState],
               store: store,
               run_id: "sra-court-2"
             )

    assert state.observation.state == :succeeded

    recorded =
      store
      |> Engine.steps("sra-court-2")
      |> Map.new(&{to_string(&1.label), &1.output})

    assert recorded |> Map.values() |> Enum.all?(&(&1.executed? == false))

    # The poison rode along as inert intent arguments only.
    output = hd(Map.values(recorded))
    assert output.arguments.input.executed? == true
    assert output.arguments.input.authority == :do
    assert output.executed? == false
  end
end
