defmodule AshPPlan.FOND.Runtime.HealthStore do
  use Agent

  def start_link(opts \\ []),
    do: Agent.start_link(fn -> %{} end, Keyword.put_new(opts, :name, __MODULE__))

  def get(s \\ __MODULE__, id),
    do: Agent.get(s, &Map.get(&1, id, %AshPPlan.FOND.Runtime.Health{}))

  def put(s \\ __MODULE__, id, h), do: Agent.update(s, &Map.put(&1, id, h))
end
