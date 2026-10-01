defmodule AshPPlan.Examples.QualifiedFulfillment.Steps.VerifyPackage do
  @moduledoc "Verify the package is packed (Fulfillment.packed) and mark the order :verified."
  use Reactor.Step
  require Ash.Query
  alias AshPPlan.Examples.QualifiedFulfillment.{Fulfillment, Order, Steps}

  @impl true
  def run(arguments, _context, _options) do
    with id when is_binary(id) <- Steps.order_id(arguments) || {:error, :order_id_missing},
         [%{packed: true}] <- read_fulfillment(id) |> normalize(),
         {:ok, order} <- Ash.get(Order, id),
         {:ok, _} <- Ash.update(order, %{}, action: :verify) do
      {:ok, %{order_id: id, order_status: :verified}}
    else
      [%{packed: false}] -> {:error, :package_not_packed}
      [] -> {:error, :fulfillment_missing}
      other -> other
    end
  end

  defp read_fulfillment(id),
    do: Fulfillment |> Ash.Query.filter(order_id == ^id) |> Ash.read!()

  defp normalize(list), do: list
end
