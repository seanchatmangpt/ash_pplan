defmodule AshPPlan.QualifiedFulfillmentDomainTest do
  @moduledoc """
  Court for the qualified-fulfillment Ash domain: real ETS-backed resources and real
  Reactor runs of AdmitOrder / VerifyPackage / CommitShipment. Anti-vacuity: a
  mutated precondition (fulfillment removed) must change the outcome from commit to
  rollback, and rollback must restore every prior write.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias AshPPlan.Examples.QualifiedFulfillment.{Domain, Fulfillment, Order, Shipment}
  alias AshPPlan.Examples.QualifiedFulfillment.Steps.{AdmitOrder, CommitShipment, VerifyPackage}

  defmodule Flow do
    @moduledoc false
    use Reactor
    input(:order_id)

    step :admit, AdmitOrder do
      argument :order_id, input(:order_id)
    end

    step :verify, VerifyPackage do
      argument :order_id, result(:admit, [:order_id])
    end

    step :commit, CommitShipment do
      argument :order_id, result(:verify, [:order_id])
    end

    return :commit
  end

  defmodule Pack do
    @moduledoc false
    use Reactor.Step
    require Ash.Query

    @impl true
    def run(%{order_id: id}, _c, _o) do
      for f <- Fulfillment |> Ash.Query.filter(order_id == ^id) |> Ash.read!(),
          do: Ash.update!(f, %{}, action: :pack)

      {:ok, %{order_id: id}}
    end
  end

  defmodule PackedFlow do
    @moduledoc false
    use Reactor
    input(:order_id)

    step :admit, AdmitOrder do
      argument :order_id, input(:order_id)
    end

    step :pack, Pack do
      argument :order_id, result(:admit, [:order_id])
    end

    step :verify, VerifyPackage do
      argument :order_id, result(:pack, [:order_id])
    end

    step :commit, CommitShipment do
      argument :order_id, result(:verify, [:order_id])
    end

    return :commit
  end

  setup do
    Domain.reset!()
    on_exit(&Domain.reset!/0)
    order = Ash.create!(Order, %{sku: "SKU-1", quantity: 2, amount: 500}, action: :place)
    {:ok, order: order}
  end

  defp fulfillments(id),
    do: Fulfillment |> Ash.Query.filter(order_id == ^id) |> Ash.read!()

  defp pack(id), do: for(f <- fulfillments(id), do: Ash.update!(f, %{}, action: :pack))
  defp status(id), do: Ash.get!(Order, id).status
  defp shipments(id), do: Shipment |> Ash.Query.filter(order_id == ^id) |> Ash.read!()

  test "admit opens a ledger and moves the order to :admitted", %{order: o} do
    assert {:ok, %{order_status: :admitted}} = AdmitOrder.run(%{order_id: o.id}, %{}, [])
    assert status(o.id) == :admitted
    assert [%{packed: false, receipts: []}] = fulfillments(o.id)
    assert {:error, _} = AdmitOrder.run(%{order_id: o.id}, %{}, [])
  end

  test "verify refuses an unpacked package, accepts a packed one", %{order: o} do
    {:ok, _} = AdmitOrder.run(%{order_id: o.id}, %{}, [])
    assert {:error, :package_not_packed} = VerifyPackage.run(%{order_id: o.id}, %{}, [])
    pack(o.id)
    assert {:ok, %{order_status: :verified}} = VerifyPackage.run(%{order_id: o.id}, %{}, [])
  end

  test "commit is one unit: order fulfilled, shipment created, receipt appended", %{order: o} do
    {:ok, _} = AdmitOrder.run(%{order_id: o.id}, %{}, [])
    pack(o.id)
    {:ok, _} = VerifyPackage.run(%{order_id: o.id}, %{}, [])

    assert {:ok, %{shipment_id: sid}} = CommitShipment.run(%{order_id: o.id}, %{}, [])
    assert status(o.id) == :fulfilled
    assert [%{id: ^sid}] = shipments(o.id)
    assert [%{receipts: [%{kind: "shipment_committed"}]}] = fulfillments(o.id)
  end

  test "failure in the last write rolls back order and shipment", %{order: o} do
    {:ok, _} = AdmitOrder.run(%{order_id: o.id}, %{}, [])
    pack(o.id)
    {:ok, _} = VerifyPackage.run(%{order_id: o.id}, %{}, [])
    # mutation: remove the ledger so the final write fails
    Enum.each(fulfillments(o.id), &Ash.destroy!/1)

    assert {:error, :fulfillment_missing} = CommitShipment.run(%{order_id: o.id}, %{}, [])
    assert status(o.id) == :verified
    assert shipments(o.id) == []
  end

  test "second commit fails on existing shipment and leaves state intact", %{order: o} do
    {:ok, _} = AdmitOrder.run(%{order_id: o.id}, %{}, [])
    pack(o.id)
    {:ok, _} = VerifyPackage.run(%{order_id: o.id}, %{}, [])
    {:ok, _} = CommitShipment.run(%{order_id: o.id}, %{}, [])
    assert {:error, _} = CommitShipment.run(%{order_id: o.id}, %{}, [])
    assert status(o.id) == :fulfilled
    assert [_] = shipments(o.id)
    assert [%{receipts: [_]}] = fulfillments(o.id)
  end

  test "undo/4 reverses a committed shipment", %{order: o} do
    {:ok, _} = AdmitOrder.run(%{order_id: o.id}, %{}, [])
    pack(o.id)
    {:ok, _} = VerifyPackage.run(%{order_id: o.id}, %{}, [])
    {:ok, res} = CommitShipment.run(%{order_id: o.id}, %{}, [])
    assert :ok = CommitShipment.undo(res, %{order_id: o.id}, %{}, [])
    assert status(o.id) == :verified
    assert shipments(o.id) == []
    assert [%{receipts: []}] = fulfillments(o.id)
  end

  test "real Reactor run compensates admit when a later step fails", %{order: o} do
    # never packed: VerifyPackage fails, AdmitOrder is undone
    assert {:error, _} = Reactor.run(Flow, %{order_id: o.id}, %{}, async?: false)
    assert status(o.id) == :new
    assert fulfillments(o.id) == []
  end

  test "real Reactor run commits end-to-end when packed", %{order: o} do
    assert {:ok, %{order_status: :fulfilled}} =
             Reactor.run(PackedFlow, %{order_id: o.id}, %{}, async?: false)

    assert status(o.id) == :fulfilled
  end
end
