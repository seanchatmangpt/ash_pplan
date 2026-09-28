defmodule AshPPlan.ActionRunTest do
  @moduledoc """
  Exercises `AshPPlan.Action.Run` through the real Ash action boundary: a real
  generic action on a real resource, `Ash.run_action/2`, and Reactor.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Action.Run.Refusal
  alias AshPPlan.Test.{PlanRunResource, TransactionalPlanRunResource}
  alias AshPPlan.Test.Steps

  @plan "https://w3id.org/ash-pplan#SubscriptionRenewal"
  @authorize "https://w3id.org/ash-pplan#AuthorizePayment"
  @renew "https://w3id.org/ash-pplan#RenewSubscription"

  defp run(action, arguments, opts \\ []) do
    PlanRunResource
    |> Ash.ActionInput.for_action(action, arguments, opts)
    |> Ash.run_action()
  end

  defp refusal!({:error, error}) do
    assert [%Refusal{} = refusal] =
             error |> Ash.Error.to_error_class() |> Map.fetch!(:errors)

    refusal
  end

  describe "argument-supplied handlers (backward compatible)" do
    test "actor, tenant and authorize? reach every step's context" do
      handlers = %{@authorize => Steps.Emit, @renew => Steps.Observe}

      assert {:ok, %{outcome: {:ok, observed}, receipt: receipt}} =
               run(:run_dynamic, %{plan_iri: @plan, handlers: handlers, input: %{order: 1}},
                 actor: %{id: "actor-7"},
                 tenant: "tenant-1",
                 authorize?: false
               )

      assert observed.actor == %{id: "actor-7"}
      assert observed.tenant == "tenant-1"
      assert observed.authorize? == false
      assert observed.input == %{order: 1}
      assert observed.predecessors == %{@authorize => @authorize}
      assert observed.run_id == receipt.run_id
      assert receipt.status == :succeeded
    end

    test "a failed Reactor outcome fails the action" do
      handlers = %{@authorize => Steps.Fail, @renew => Steps.Observe}

      assert {:error, error} =
               run(:run_dynamic, %{plan_iri: @plan, handlers: handlers, input: nil})

      assert Exception.message(error) =~ "step failed"
    end

    test "a halted Reactor outcome is refused by default" do
      handlers = %{@authorize => Steps.HaltUntilResumed, @renew => Steps.Observe}

      result = run(:run_dynamic, %{plan_iri: @plan, handlers: handlers, input: nil})

      assert %Refusal{reason: :reactor_halted, details: %{receipt: %{status: :halted}}} =
               refusal!(result)
    end

    test "a compiler refusal fails the action" do
      assert {:error, _error} =
               run(:run_dynamic, %{plan_iri: @plan, handlers: %{@authorize => Steps.Emit}})
    end

    test "non-map handlers are refused" do
      result = run(:run_dynamic, %{plan_iri: @plan, handlers: [:not_a_map], input: nil})

      assert %Refusal{reason: :invalid_action_arguments, details: %{argument: :handlers}} =
               refusal!(result)
    end
  end

  describe "server-configured handlers and plan allowlist" do
    test "configured handlers execute without an argument" do
      assert {:ok, %{outcome: {:ok, observed}}} =
               run(:run_configured, %{plan_iri: @plan, input: :configured}, actor: %{id: 1})

      assert observed.input == :configured
      assert observed.actor == %{id: 1}
    end

    test "an argument-supplied handler map is refused when handlers are configured" do
      result =
        run(:run_configured, %{
          plan_iri: @plan,
          handlers: %{@authorize => Steps.Fail, @renew => Steps.Fail},
          input: nil
        })

      assert %Refusal{reason: :handlers_argument_refused} = refusal!(result)
    end

    test "a plan outside the allowlist is refused" do
      result = run(:run_configured, %{plan_iri: "urn:plan:not-allowed", input: nil})

      assert %Refusal{reason: :plan_not_allowed, details: %{plan_iri: "urn:plan:not-allowed"}} =
               refusal!(result)
    end
  end

  describe "halt admission" do
    test "is refused unless allow_halt? is configured" do
      assert %Refusal{reason: :reactor_halted} =
               refusal!(run(:run_halting, %{plan_iri: @plan, input: nil}))
    end

    test "an admitted halt returns the halted Reactor for the application to capture" do
      assert {:ok, %{outcome: {:halted, reactor}, receipt: receipt}} =
               run(:run_halting_admitted, %{plan_iri: @plan, input: nil})

      assert receipt.status == :halted

      assert {:ok, _continuation} =
               AshPPlan.capture_continuation(@plan, receipt.run_id, reactor)
    end
  end

  describe "inside a data-layer transaction" do
    setup do
      dir = Path.join(System.tmp_dir!(), "ash_pplan_mnesia_#{System.unique_integer([:positive])}")
      Application.put_env(:mnesia, :dir, String.to_charlist(dir))
      Ash.DataLayer.Mnesia.start(AshPPlan.Test.PlanRunDomain, [TransactionalPlanRunResource])

      on_exit(fn ->
        :mnesia.stop()
        File.rm_rf(dir)
      end)
    end

    test "every step runs synchronously inside the action's transaction" do
      assert {:ok, %{outcome: {:ok, observed}}} =
               TransactionalPlanRunResource
               |> Ash.ActionInput.for_action(:run_in_transaction, %{plan_iri: @plan, input: nil})
               |> Ash.run_action()

      assert observed.in_transaction? == true
      assert observed.pid == self()
    end
  end
end
