defmodule AshPPlan.Reactor.GenericActionBridgeCourtTest do
  @moduledoc """
  Chicago court for the generated Reactor-as-generic-action bridge: a real
  Ash resource with a real generic action whose `run` is a real Reactor
  module, executed through `Ash.run_action/1`. No mocks.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.GenericActionBridge

  test "runs the bound Reactor through the real Ash generic action" do
    assert :ok = GenericActionBridge.check_input_mapping()

    assert {:ok, %{bridged: %{value: 21}}} =
             GenericActionBridge
             |> Ash.ActionInput.for_action(:run_reactor, %{value: 21})
             |> Ash.run_action()
  end

  test "the actor/tenant/authorize? context reaches the Reactor step" do
    assert {:ok, %{bridged: %{value: 2}}} =
             GenericActionBridge
             |> Ash.ActionInput.for_action(:run_reactor, %{value: 2},
               actor: %{id: "a-1"},
               tenant: "t-1",
               authorize?: false
             )
             |> Ash.run_action()
  end

  test "a missing required argument is refused by Ash before the Reactor runs" do
    assert {:error, error} =
             GenericActionBridge
             |> Ash.ActionInput.for_action(:run_reactor, %{})
             |> Ash.run_action()

    assert Exception.message(error) =~ "value"
  end
end
