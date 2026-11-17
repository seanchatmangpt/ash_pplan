defmodule AshPPlan.Action.RunAllowlistCourtTest do
  @moduledoc """
  Court for the `plans:` allowlist and server-fixed `handlers:` of
  `AshPPlan.Action.Run`, exercised through the real Ash action boundary
  (`Ash.ActionInput.for_action/3` + `Ash.run_action/1`) and the real Reactor.

  Side effects are witnessed by a named `Agent` counter that every counting
  step increments; a refusal must leave it at 0.

  Plan and step IRIs are the ones materialised from `ontology.ttl` into
  `AshPPlan.Catalog.Plan` (`SubscriptionRenewal`, `wf_Activation`); there is
  no `WorkOrderLifecycle` plan in the catalog, so `SubscriptionRenewal` stands
  in as the clearinghouse plan and `wf_Activation` as the plan that one
  resource refuses and its sibling admits.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Action.Run.Refusal

  @counter __MODULE__.Counter

  @clearinghouse_plan "https://w3id.org/ash-pplan#SubscriptionRenewal"
  @authorize "https://w3id.org/ash-pplan#AuthorizePayment"
  @renew "https://w3id.org/ash-pplan#RenewSubscription"

  @sibling_plan "https://w3id.org/ash-pplan#wf_Activation"
  @activation_steps [
    "https://w3id.org/ash-pplan#task_activation_apply_active_event",
    "https://w3id.org/ash-pplan#task_activation_approve_account",
    "https://w3id.org/ash-pplan#task_activation_confirm_active"
  ]

  defmodule Steps.Count do
    @moduledoc "Increments the court's Agent counter and returns its step IRI."
    use Reactor.Step

    @impl true
    def run(_arguments, context, _options) do
      Agent.update(AshPPlan.Action.RunAllowlistCourtTest.Counter, &(&1 + 1))
      {:ok, context.ash_pplan.step_iri}
    end
  end

  defmodule Steps.CountAndObserve do
    @moduledoc "Increments the counter and reports input + predecessor results."
    use Reactor.Step

    @impl true
    def run(arguments, context, _options) do
      Agent.update(AshPPlan.Action.RunAllowlistCourtTest.Counter, &(&1 + 1))

      {:ok,
       %{
         input: Map.get(arguments, :input),
         predecessors: AshPPlan.predecessor_results(arguments, context),
         run_id: Map.get(context, :run_id),
         actor: Map.get(context, :actor)
       }}
    end
  end

  defmodule Steps.Halt do
    @moduledoc "Halts the run (parks it) without touching the counter."
    use Reactor.Step

    @impl true
    def run(_arguments, _context, _options), do: {:halt, :awaiting_clearinghouse}
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshPPlan.Action.RunAllowlistCourtTest.Clearinghouse
      resource AshPPlan.Action.RunAllowlistCourtTest.Sibling
    end
  end

  defmodule Clearinghouse do
    @moduledoc "Allowlists only SubscriptionRenewal with server-fixed handlers."
    use Ash.Resource,
      domain: AshPPlan.Action.RunAllowlistCourtTest.Domain,
      data_layer: Ash.DataLayer.Ets

    alias AshPPlan.Action.RunAllowlistCourtTest.Steps

    @plan "https://w3id.org/ash-pplan#SubscriptionRenewal"
    @authorize "https://w3id.org/ash-pplan#AuthorizePayment"
    @renew "https://w3id.org/ash-pplan#RenewSubscription"

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]

      action :execute_clearinghouse_plan, :map do
        argument :plan_iri, :string, allow_nil?: false
        argument :input, :term

        run {AshPPlan.Action.Run,
             handlers: %{@authorize => Steps.Count, @renew => Steps.CountAndObserve},
             plans: [@plan],
             allow_halt?: true}
      end

      # Handler map deliberately omits RenewSubscription.
      action :execute_missing_handler, :map do
        argument :plan_iri, :string, allow_nil?: false
        argument :input, :term

        run {AshPPlan.Action.Run,
             handlers: %{@authorize => Steps.Count}, plans: [@plan], allow_halt?: true}
      end

      action :execute_parking, :map do
        argument :plan_iri, :string, allow_nil?: false
        argument :input, :term

        run {AshPPlan.Action.Run,
             handlers: %{@authorize => Steps.Halt, @renew => Steps.Count},
             plans: [@plan],
             allow_halt?: true}
      end

      action :execute_parking_refused, :map do
        argument :plan_iri, :string, allow_nil?: false
        argument :input, :term

        run {AshPPlan.Action.Run,
             handlers: %{@authorize => Steps.Halt, @renew => Steps.Count}, plans: [@plan]}
      end
    end
  end

  defmodule Sibling do
    @moduledoc "Allowlists wf_Activation, the plan Clearinghouse refuses."
    use Ash.Resource,
      domain: AshPPlan.Action.RunAllowlistCourtTest.Domain,
      data_layer: Ash.DataLayer.Ets

    alias AshPPlan.Action.RunAllowlistCourtTest.Steps

    @plan "https://w3id.org/ash-pplan#wf_Activation"
    @steps [
      "https://w3id.org/ash-pplan#task_activation_apply_active_event",
      "https://w3id.org/ash-pplan#task_activation_approve_account",
      "https://w3id.org/ash-pplan#task_activation_confirm_active"
    ]

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]

      action :execute_activation, :map do
        argument :plan_iri, :string, allow_nil?: false
        argument :input, :term

        run {AshPPlan.Action.Run,
             handlers: Map.new(@steps, &{&1, Steps.Count}), plans: [@plan], allow_halt?: true}
      end
    end
  end

  setup do
    start_supervised!(%{
      id: @counter,
      start: {Agent, :start_link, [fn -> 0 end, [name: @counter]]}
    })

    :ok
  end

  defp run(resource, action, arguments, opts \\ []) do
    resource
    |> Ash.ActionInput.for_action(action, arguments, opts)
    |> Ash.run_action()
  end

  defp count, do: Agent.get(@counter, & &1)

  defp refusal!({:error, error}) do
    assert [%Refusal{} = refusal] =
             error |> Ash.Error.to_error_class() |> Map.fetch!(:errors)

    refusal
  end

  describe "allowlisted plan" do
    test "runs with the server-fixed handlers and returns the real result shape" do
      assert {:ok, %{outcome: {:ok, observed}, receipt: receipt}} =
               run(
                 Clearinghouse,
                 :execute_clearinghouse_plan,
                 %{plan_iri: @clearinghouse_plan, input: %{work_order: 42}},
                 actor: %{id: "clerk-1"}
               )

      assert observed.input == %{work_order: 42}
      assert observed.predecessors == %{@authorize => @authorize}
      assert observed.actor == %{id: "clerk-1"}
      assert observed.run_id == receipt.run_id
      assert receipt.status == :succeeded
      assert count() == 2
    end
  end

  describe "plan outside the allowlist" do
    test "is refused as :plan_not_allowed with zero side effects" do
      result =
        run(Clearinghouse, :execute_clearinghouse_plan, %{plan_iri: @sibling_plan, input: nil})

      assert %Refusal{reason: :plan_not_allowed, details: %{plan_iri: @sibling_plan}} =
               refusal!(result)

      assert count() == 0
    end

    test "non-vacuity: the same plan succeeds in a sibling resource that allowlists it" do
      assert {:ok, %{outcome: {:ok, _result}, receipt: receipt}} =
               run(Sibling, :execute_activation, %{plan_iri: @sibling_plan, input: nil})

      assert receipt.status == :succeeded
      assert count() == length(@activation_steps)
    end

    test "the sibling refuses the clearinghouse plan in turn" do
      result = run(Sibling, :execute_activation, %{plan_iri: @clearinghouse_plan, input: nil})

      assert %Refusal{reason: :plan_not_allowed, details: %{plan_iri: @clearinghouse_plan}} =
               refusal!(result)

      assert count() == 0
    end
  end

  describe "step without a handler" do
    test "is refused by the compiler before any step runs" do
      assert {:error, error} =
               run(Clearinghouse, :execute_missing_handler, %{
                 plan_iri: @clearinghouse_plan,
                 input: nil
               })

      message = Exception.message(error)
      assert message =~ "ash_pplan compiler refused missing_handlers"
      assert message =~ @renew
      refute message =~ "#{@authorize}\""
      assert count() == 0
    end
  end

  describe "allow_halt?" do
    test "a parked plan is admitted as {:halted, reactor} and successors never run" do
      assert {:ok, %{outcome: {:halted, reactor}, receipt: receipt}} =
               run(Clearinghouse, :execute_parking, %{plan_iri: @clearinghouse_plan, input: nil})

      assert receipt.status == :halted
      assert is_binary(receipt.run_id) or is_reference(receipt.run_id)
      assert AshPPlan.Reactor.Durable.Portable.portable?(reactor)
      assert count() == 0
    end

    test "without allow_halt? the park is refused as :reactor_halted" do
      result =
        run(Clearinghouse, :execute_parking_refused, %{plan_iri: @clearinghouse_plan, input: nil})

      assert %Refusal{reason: :reactor_halted, details: %{receipt: %{status: :halted}}} =
               refusal!(result)

      assert count() == 0
    end
  end
end
