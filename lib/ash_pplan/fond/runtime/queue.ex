defmodule AshPPlan.FOND.Runtime.Queue do
  def new, do: :queue.new()
  def push(q, x), do: :queue.in(x, q)

  def pop(q) do
    case :queue.out(q) do
      {{:value, v}, r} -> {:ok, v, r}
      {:empty, _} -> {:empty, q}
    end
  end
end
