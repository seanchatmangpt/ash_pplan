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

  @doc "Drop every ETS table of the example (test isolation)."
  def reset! do
    for r <- Ash.Domain.Info.resources(__MODULE__), do: Ash.DataLayer.Ets.stop(r)
    :ok
  end
end
