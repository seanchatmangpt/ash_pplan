defmodule AshPPlan.FOND.Runtime.RegistryTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Runtime.{Registry, ProviderSpec}

  test "filters providers by capability" do
    {:ok, p} = Registry.start_link(name: nil)
    :ok = Registry.register(p, %ProviderSpec{id: :p, module: __MODULE__, capabilities: [:plan]})
    assert [%{id: :p}] = Registry.providers(p, :plan)
    assert [] = Registry.providers(p, :other)
  end
end
