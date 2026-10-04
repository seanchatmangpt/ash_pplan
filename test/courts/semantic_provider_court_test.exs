# Zach-Daniel-style court for the ap:Provider/ap:Realization semantics of
# ontology.ttl: providers realize capabilities via adapters, authority never
# exceeds :construct, and "qualification refuses any authority above
# :construct; availability is not authority".
defmodule AshPPlan.Courts.SemanticProviderCourtTest do
  use ExUnit.Case, async: true

  alias AshPPlan.Providers.{Order, Payment, PaymentBackup, Registry}

  @order_ceiling [:none, :observe, :select, :plan, :construct]

  # Ontology lane invariant: the provider pool is real and non-empty before any
  # qualify/resolve assertion runs (anti-vacuity gate).
  test "generated provider pool is non-empty" do
    providers = Registry.new([Order, Payment, PaymentBackup]) |> Registry.providers()
    assert providers != []
    assert length(providers) == 3
  end

  test "generated provider qualifies a real requirement within ceiling" do
    requirement = %{capability: "Order.Admit", authority: :plan}
    assert :ok == Order.qualify(requirement, %{})

    assert {:ok, realization} = Order.realize(requirement, %{})
    assert realization.capability == "Order.Admit"
    assert realization.provider == :order
    assert realization.binding.adapter == :qf_ledger
    assert realization.binding.op == :order_admit
  end

  test "refuses a requirement needing authority above the provider's declared authorities" do
    # Provider declares ceiling :construct; :do is outside every declared authority.
    assert {:error,
            %{reason: :no_qualified_provider, rejected: [], detail: {:authority_refused, :do}}} =
             Registry.new([Order])
             |> Registry.resolve(%{capability: "Order.Admit", authority: :do}, %{})

    # Context ceiling below what the requirement wants is likewise refused
    # before any provider is consulted: availability is not authority.
    assert {:error,
            %{
              reason: :no_qualified_provider,
              detail: {:authority_exceeds_ceiling, :plan, :observe}
            }} =
             Registry.new([Order])
             |> Registry.resolve(%{capability: "Order.Admit", authority: :plan}, %{
               ceiling: :observe
             })

    # Direct qualification at the provider surface also refuses above-ceiling
    # authority, typed, never crashing.
    assert {:error, {:authority_exceeds_ceiling, :do}} =
             Order.qualify(%{capability: "Order.Admit", authority: :do}, %{})
  end

  test "registry resolution picks the lowest-cost qualified provider" do
    requirement = %{capability: "Payment.Authorize"}

    assert {:ok, %{provider: provider, reason: reason}} =
             Registry.new([PaymentBackup, Payment])
             |> Registry.resolve(requirement, %{})

    assert provider == Payment
    assert reason =~ "lowest cost"
  end

  test "a capability with no qualified provider returns a typed no_qualified_provider error" do
    assert {:error, %{reason: :no_qualified_provider, rejected: rejected}} =
             Registry.new([Payment, PaymentBackup])
             |> Registry.resolve(%{capability: "Order.Admit"}, %{})

    assert length(rejected) == 2

    assert Enum.all?(rejected, fn {mod, reason} ->
             mod in [Payment, PaymentBackup] and reason == :capability_unsupported
           end)
  end
end
