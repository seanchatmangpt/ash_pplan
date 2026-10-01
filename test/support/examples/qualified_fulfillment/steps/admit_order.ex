defmodule AshPPlan.Examples.QualifiedFulfillment.Steps.AdmitOrder do
  @moduledoc "Admit an order (:new -> :admitted) and open its Fulfillment ledger. Undo reverts both."
  use Reactor.Step
  alias AshPPlan.Examples.QualifiedFulfillment.{Fulfillment, Order, Steps}

  @impl true
  def run(arguments, _context, _options) do
    with id when is_binary(id) <- Steps.order_id(arguments) || {:error, :order_id_missing},
         {:ok, order} <- Ash.get(Order, id),
         {:ok, _} <- Ash.update(order, %{}, action: :admit),
         {:ok, _} <- Ash.create(Fulfillment, %{order_id: id}, action: :open) do
      {:ok, %{order_id: id, order_status: :admitted}}
    end
  end

  @impl true
  def undo(%{order_id: id}, _arguments, _context, _options) do
    require Ash.Query

    Fulfillment
    |> Ash.Query.filter(order_id == ^id)
    |> Ash.read!()
    |> Enum.each(&Ash.destroy!/1)

    with {:ok, order} <- Ash.get(Order, id),
         {:ok, _} <- Ash.update(order, %{}, action: :revert_admit) do
      :ok
    else
      {:error, e} -> {:error, e}
    end
  end
end
