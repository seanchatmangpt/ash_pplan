defmodule AshPPlan.Examples.QualifiedFulfillment.PaymentAuthorization do
  @moduledoc "Record of a payment authorization outcome for an order."
  use Ash.Resource,
    domain: AshPPlan.Examples.QualifiedFulfillment.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? false
  end

  attributes do
    uuid_primary_key :id
    attribute :order_id, :uuid, allow_nil?: false, public?: true
    attribute :amount, :integer, allow_nil?: false, public?: true

    attribute :status, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:authorized, :declined, :unavailable, :timeout]]
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      accept [:order_id, :amount, :status]
    end
  end
end
