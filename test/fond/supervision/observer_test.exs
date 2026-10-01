defmodule AshPPlan.FOND.Supervision.ObserverTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Supervision.Observer
  test "normalizes observations" do
    assert {:ok,{:s,:o}}=Observer.normalize(%{state: :s,outcome: :o}); assert {:error,_}=Observer.normalize(:bad)
  end
end
