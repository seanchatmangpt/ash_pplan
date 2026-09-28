defmodule AshPPlan.FOND.Supervision.Observer do
  def normalize(%{state:s,outcome:o}), do: {:ok,{s,o}}
  def normalize({s,o}), do: {:ok,{s,o}}
  def normalize(x), do: {:error,{:invalid_observation,x}}
end
