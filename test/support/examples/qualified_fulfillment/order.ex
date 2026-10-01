defmodule AshPPlan.Examples.QualifiedFulfillment.Order do
  @moduledoc """
  An order moving :new -> :admitted -> :verified -> :fulfilled. Each transition
  action validates its source state; `revert_*`/`unfulfill` are the compensations.
  """
  use Ash.Resource,
    domain: AshPPlan.Examples.QualifiedFulfillment.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? false
  end

  attributes do
    uuid_primary_key :id
    attribute :sku, :string, allow_nil?: false, public?: true
    attribute :quantity, :integer, allow_nil?: false, default: 1, public?: true
    attribute :amount, :integer, allow_nil?: false, default: 0, public?: true

    attribute :status, :atom,
      allow_nil?: false,
      default: :new,
      public?: true,
      constraints: [one_of: [:new, :admitted, :verified, :fulfilled]]
  end

  actions do
    defaults [:read, :destroy]

    create :place do
      accept [:sku, :quantity, :amount]
      validate compare(:quantity, greater_than: 0)
    end

    update :admit do
      require_atomic? false
      validate attribute_equals(:status, :new)
      change set_attribute(:status, :admitted)
    end

    update :verify do
      require_atomic? false
      validate attribute_equals(:status, :admitted)
      change set_attribute(:status, :verified)
    end

    update :fulfill do
      require_atomic? false
      validate attribute_equals(:status, :verified)
      change set_attribute(:status, :fulfilled)
    end

    update :unfulfill do
      require_atomic? false
      validate attribute_equals(:status, :fulfilled)
      change set_attribute(:status, :verified)
    end

    update :revert_admit do
      require_atomic? false
      validate attribute_equals(:status, :admitted)
      change set_attribute(:status, :new)
    end
  end
end
