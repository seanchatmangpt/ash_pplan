defmodule AshPPlan.Examples.QualifiedFulfillment.Domain do
  @moduledoc """
  Ash domain for the qualified-fulfillment example: Order, PaymentAuthorization,
  Fulfillment and Shipment, all on the ETS data layer.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshPPlan.Examples.QualifiedFulfillment.Order
    resource AshPPlan.Examples.QualifiedFulfillment.PaymentAuthorization
    resource AshPPlan.Examples.QualifiedFulfillment.Fulfillment
    resource AshPPlan.Examples.QualifiedFulfillment.Shipment
  end

  @doc "Drop every ETS table of the example (test isolation); returns once every table is gone."
  def reset! do
    for r <- Ash.Domain.Info.resources(__MODULE__) do
      Ash.DataLayer.Ets.stop(r)
      await_gone(r)
    end

    :ok
  end

  # Ash stops a table's manager asynchronously (the table dies with it); a next test that starts
  # before that sees a half-dead table. Block until neither manager nor table exists.
  defp await_gone(resource, tries \\ 400) do
    case Ash.DataLayer.Ets.table_name(resource, nil, false) do
      {:ok, table} ->
        gone? =
          Process.whereis(Module.concat(table, TableManager)) == nil and
            :ets.whereis(table) == :undefined

        cond do
          gone? -> :ok
          tries == 0 -> :ok
          true -> Process.sleep(5) && await_gone(resource, tries - 1)
        end

      _ ->
        :ok
    end
  end
end
