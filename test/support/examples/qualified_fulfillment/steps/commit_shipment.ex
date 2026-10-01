defmodule AshPPlan.Examples.QualifiedFulfillment.Steps.CommitShipment do
  @moduledoc """
  Commit a shipment as ONE unit: mark the order fulfilled, create the Shipment,
  append a fulfillment receipt. Ash.DataLayer.Ets declares `can?(:transact)` false, so
  atomicity is realized as a saga inside `run/3`: the first failing write rolls back
  every prior write (reverse order) before the error is returned. `undo/4` applies the
  inverse to an already-committed result, so Reactor compensation also works.
  """
  use Reactor.Step
  require Ash.Query
  alias AshPPlan.Examples.QualifiedFulfillment.{Fulfillment, Order, Shipment, Steps}

  @impl true
  def run(arguments, _context, _options) do
    with id when is_binary(id) <- Steps.order_id(arguments) || {:error, :order_id_missing} do
      commit(id)
    end
  end

  @doc "Commit for `order_id`; all-or-nothing."
  @spec commit(String.t()) :: {:ok, map()} | {:error, term()}
  def commit(id) do
    [&fulfill_order/1, &create_shipment/1, &append_receipt/1]
    |> Enum.reduce_while({:ok, []}, fn step, {:ok, done} ->
      case step.(id) do
        {:ok, undo, info} -> {:cont, {:ok, [{undo, info} | done]}}
        {:error, e} -> {:halt, {:error, e, done}}
      end
    end)
    |> case do
      {:ok, done} ->
        shipment_id = done |> Enum.find_value(fn {_, i} -> i[:shipment_id] end)
        {:ok, %{order_id: id, order_status: :fulfilled, shipment_id: shipment_id}}

      {:error, e, done} ->
        Enum.each(done, fn {undo, _} -> undo.() end)
        {:error, e}
    end
  end

  @impl true
  def undo(%{order_id: id, shipment_id: sid}, _arguments, _context, _options) do
    with {:ok, s} <- Ash.get(Shipment, sid), :ok <- Ash.destroy(s) do
      drop_last_receipt(id)
      revert_order(id)
      :ok
    end
  end

  defp fulfill_order(id) do
    with {:ok, order} <- Ash.get(Order, id),
         {:ok, _} <- Ash.update(order, %{}, action: :fulfill) do
      {:ok, fn -> revert_order(id) end, %{}}
    end
  end

  defp revert_order(id) do
    with {:ok, order} <- Ash.get(Order, id), do: Ash.update(order, %{}, action: :unfulfill)
  end

  defp create_shipment(id) do
    case Shipment |> Ash.Query.filter(order_id == ^id) |> Ash.read!() do
      [] ->
        with {:ok, s} <-
               Ash.create(Shipment, %{order_id: id, tracking: "TRK-" <> String.slice(id, 0, 8)}) do
          {:ok, fn -> Ash.destroy(s) end, %{shipment_id: s.id}}
        end

      _ ->
        {:error, :shipment_exists}
    end
  end

  defp append_receipt(id) do
    case Fulfillment |> Ash.Query.filter(order_id == ^id) |> Ash.read!() do
      [f] ->
        before = f.receipts

        with {:ok, _} <-
               Ash.update(f, %{receipt: %{kind: "shipment_committed", order_id: id}},
                 action: :append_receipt
               ) do
          {:ok, fn -> restore_receipts(id, before) end, %{}}
        end

      [] ->
        {:error, :fulfillment_missing}
    end
  end

  defp restore_receipts(id, before) do
    for f <- Fulfillment |> Ash.Query.filter(order_id == ^id) |> Ash.read!(),
        do: Ash.update!(f, %{receipts: before}, action: :set_receipts)
  end

  defp drop_last_receipt(id) do
    for f <- Fulfillment |> Ash.Query.filter(order_id == ^id) |> Ash.read!() do
      Ash.update!(f, %{receipts: Enum.drop(f.receipts, -1)}, action: :set_receipts)
    end
  end
end
