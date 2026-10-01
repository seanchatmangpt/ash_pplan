defmodule AshPPlan.Examples.QualifiedFulfillment.Fulfillment do
  @moduledoc "Per-order fulfillment ledger: packed flag and an append-only receipt list."
  use Ash.Resource,
    domain: AshPPlan.Examples.QualifiedFulfillment.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? false
  end

  attributes do
    uuid_primary_key :id
    attribute :order_id, :uuid, allow_nil?: false, public?: true
    attribute :packed, :boolean, allow_nil?: false, default: false, public?: true
    attribute :receipts, {:array, :map}, allow_nil?: false, default: [], public?: true
  end

  actions do
    defaults [:read, :destroy]

    create :open do
      accept [:order_id]
    end

    update :pack do
      change set_attribute(:packed, true)
    end

    update :set_receipts do
      accept [:receipts]
    end

    update :append_receipt do
      require_atomic? false
      argument :receipt, :map, allow_nil?: false

      change fn changeset, _ ->
        r = Ash.Changeset.get_argument(changeset, :receipt)
        existing = Ash.Changeset.get_attribute(changeset, :receipts) || []
        Ash.Changeset.force_change_attribute(changeset, :receipts, existing ++ [r])
      end
    end
  end
end
