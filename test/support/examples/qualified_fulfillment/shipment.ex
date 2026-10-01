defmodule AshPPlan.Examples.QualifiedFulfillment.Shipment do
  @moduledoc "A committed shipment; at most one per order (checked by CommitShipment)."
  use Ash.Resource,
    domain: AshPPlan.Examples.QualifiedFulfillment.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? false
  end

  attributes do
    uuid_primary_key :id
    attribute :order_id, :uuid, allow_nil?: false, public?: true
    attribute :tracking, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:order_id, :tracking]
    end
  end
end
