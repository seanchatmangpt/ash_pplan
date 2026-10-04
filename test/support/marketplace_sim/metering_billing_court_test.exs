defmodule Support.MarketplaceSim.MeteringBillingCourtTest do
  @moduledoc """
  Chicago-style court over the marketplace-sim metering and billing vendors:
  real GenServer process state and real ETS tables, no doubles.
  """

  use ExUnit.Case, async: false

  alias Vendor.Billing
  alias Vendor.MeteringServer

  setup do
    start_supervised!(MeteringServer)
    Billing.start()
    :ok
  end

  describe "metering" do
    test "happy path aggregates posted usage" do
      t0 = ~U[2026-10-03 00:00:00Z] |> DateTime.to_unix()
      t1 = ~U[2026-10-03 01:00:00Z] |> DateTime.to_unix()

      assert {:ok, :recorded} =
               MeteringServer.post_usage("ent-1", "evt-1", "tokens", 100, t0 + 10)

      assert {:ok, :recorded} =
               MeteringServer.post_usage("ent-1", "evt-2", "tokens", 250, t0 + 20)

      assert {:ok, 350} = MeteringServer.aggregate("ent-1", {t0, t1})
      assert {:ok, %{"ent-1" => 350}} = MeteringServer.totals()
    end

    test "duplicate usage_event_id is a no-op, no double count" do
      t0 = ~U[2026-10-03 00:00:00Z] |> DateTime.to_unix()

      assert {:ok, :recorded} = MeteringServer.post_usage("ent-1", "evt-1", "tokens", 100, t0)
      assert {:ok, :duplicate} = MeteringServer.post_usage("ent-1", "evt-1", "tokens", 100, t0)
      assert {:ok, :duplicate} = MeteringServer.post_usage("ent-1", "evt-1", "requests", 999, t0)

      assert {:ok, 100} = MeteringServer.aggregate("ent-1", {t0, t0 + 60})
    end

    test "same event id under different entitlements does not dedupe across entitlements" do
      t0 = ~U[2026-10-03 00:00:00Z] |> DateTime.to_unix()

      assert {:ok, :recorded} = MeteringServer.post_usage("ent-1", "evt-1", "tokens", 10, t0)
      assert {:ok, :recorded} = MeteringServer.post_usage("ent-2", "evt-1", "tokens", 20, t0)

      assert {:ok, %{"ent-1" => 10, "ent-2" => 20}} = MeteringServer.totals()
    end

    test "half-open window: event exactly at to_ts is excluded" do
      t0 = ~U[2026-10-03 00:00:00Z] |> DateTime.to_unix()
      t1 = ~U[2026-10-03 01:00:00Z] |> DateTime.to_unix()

      assert {:ok, :recorded} = MeteringServer.post_usage("ent-1", "evt-1", "tokens", 100, t0)
      assert {:ok, :recorded} = MeteringServer.post_usage("ent-1", "evt-2", "tokens", 200, t1)

      assert {:ok, 100} = MeteringServer.aggregate("ent-1", {t0, t1})
      assert {:ok, 300} = MeteringServer.aggregate("ent-1", {t0, t1 + 1})
    end

    test "anti-vacuity: zero usage yields zero aggregate" do
      t0 = ~U[2026-10-03 00:00:00Z] |> DateTime.to_unix()

      assert {:ok, 0} = MeteringServer.aggregate("ent-never-posted", {t0, t0 + 60})
      assert {:ok, %{}} = MeteringServer.totals()
    end
  end

  describe "billing" do
    test "allocate -> record -> balance draws down committed spend" do
      assert :ok = Billing.allocate("pool-edp", 10_000)

      assert {:ok, :recorded} = Billing.record("pool-edp", 4_000, "inv-1")
      assert {:ok, {10_000, 4_000, 6_000}} = Billing.balance("pool-edp")

      assert {:ok, :recorded} = Billing.record("pool-edp", 6_000, "inv-2")
      assert {:ok, {10_000, 10_000, 0}} = Billing.balance("pool-edp")
    end

    test "overdraw refusal exact tuple, committed spend unchanged" do
      assert :ok = Billing.allocate("pool-edp", 5_000)

      assert {:error, {:overdraw, 5_001, 5_000}} = Billing.record("pool-edp", 5_001, "inv-big")
      assert {:ok, {5_000, 0, 5_000}} = Billing.balance("pool-edp")
    end

    test "duplicate ref is a no-op without a second drawdown" do
      assert :ok = Billing.allocate("pool-edp", 10_000)

      assert {:ok, :recorded} = Billing.record("pool-edp", 3_000, "inv-1")
      assert {:ok, :duplicate} = Billing.record("pool-edp", 3_000, "inv-1")

      assert {:ok, {10_000, 3_000, 7_000}} = Billing.balance("pool-edp")
    end

    test "record against unknown pool is refused" do
      assert {:error, :unknown_pool} = Billing.record("pool-ghost", 100, "inv-ghost")
      assert {:error, :unknown_pool} = Billing.balance("pool-ghost")
    end
  end
end
