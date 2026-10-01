defmodule AshPPlan.Examples.QualifiedFulfillment.Steps do
  @moduledoc """
  Real Reactor steps over the qualified-fulfillment Ash resources, plus the shared
  lenient argument reader: the order id is found under `:order_id`, in the workflow
  `:input` map, or in any upstream result map.
  """

  @doc "Find the order id in step arguments."
  @spec order_id(map()) :: String.t() | nil
  def order_id(arguments) do
    arguments
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.find_value(fn
      {:order_id, v} when is_binary(v) -> v
      {_k, %{} = m} when not is_struct(m) -> Map.get(m, :order_id)
      _ -> nil
    end)
  end
end
