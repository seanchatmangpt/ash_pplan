defmodule AshPPlan.ReactorAdaptersAshReactorExtendedCourtTest do
  @moduledoc """
  Chicago court for the generated companion adapter
  (`AshPPlan.Reactor.Adapters.AshReactorExtended`): every op resolves through
  the generated @table, and the resolved real Ash.Reactor step modules are
  executed for real against a real in-test Ash resource on the ETS data
  layer. No mocks; assertions are on real returned state.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Adapters.AshReactorExtended

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshPPlan.ReactorAdaptersAshReactorExtendedCourtTest.Item
    end
  end

  defmodule Item do
    @moduledoc false
    use Ash.Resource,
      domain: AshPPlan.ReactorAdaptersAshReactorExtendedCourtTest.Domain,
      data_layer: Ash.DataLayer.Ets

    ets do
      private? false
    end

    attributes do
      uuid_primary_key :id
      attribute :sku, :string, allow_nil?: false, public?: true
      attribute :quantity, :integer, allow_nil?: false, default: 1, public?: true
    end

    actions do
      defaults [:read, :destroy]

      create :place do
        accept [:sku, :quantity]
      end

      read :get_by_sku do
        argument :sku, :string, allow_nil?: false
        filter expr(sku == ^arg(:sku))
        get? true
      end

      action :shout, :string do
        argument :text, :string, allow_nil?: false
        run fn input, _ctx -> {:ok, String.upcase(input.arguments.text)} end
      end
    end

    calculations do
      calculate :shouted_sku, :string, fn records, _ctx ->
        {:ok, Enum.map(records, &String.upcase(&1.sku))}
      end
    end
  end

  @opts [domain: Domain]

  setup do
    Ash.DataLayer.Ets.stop(Item)
    # stop/1 is a bare Process.exit(pid, :shutdown): the table-owning
    # TableManager tears down asynchronously, so the next test can hit
    # {:error, {:already_started, _}} while the dying manager still holds the
    # registered name and then wrap a table that no longer exists ("table
    # identifier does not refer to an existing ETS table"). Wait for the old
    # manager to be fully gone so the next op starts a clean one.
    table = Ash.DataLayer.Ets.Info.table(Item)

    wait_until(fn ->
      Process.whereis(Module.concat(table, TableManager)) == nil
    end)

    :ok
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("ETS TableManager did not stop")

      true ->
        Process.sleep(1)
        wait_until(fun, deadline)
    end
  end

  defp run_op(op, arguments, options) do
    assert {:ok, {step, base}} = AshReactorExtended.step(op, @opts ++ options)
    assert Code.ensure_loaded?(step)
    assert function_exported?(step, :run, 3)

    step.run(arguments, %{}, base ++ options)
  end

  test "every generated op resolves to a loaded Reactor.Step module" do
    for op <- AshReactorExtended.ops() do
      assert {:ok, {step, kw}} = AshReactorExtended.step(op, @opts)
      assert is_list(kw)
      assert Code.ensure_loaded?(step), "#{op} -> #{inspect(step)} not loadable"
      assert function_exported?(step, :run, 3), "#{op} -> #{inspect(step)}"
    end
  end

  test "ash_read_one runs a real get action through the generated clause" do
    {:ok, item} =
      Ash.create(Ash.Changeset.for_create(Item, :place, %{sku: "R1", quantity: 2}))

    assert {:ok, found} =
             run_op(:ash_read_one, %{input: %{sku: "R1"}},
               resource: Item,
               action: :get_by_sku
             )

    assert found.id == item.id

    assert {:ok, nil} =
             run_op(:ash_read_one, %{input: %{sku: "absent"}},
               resource: Item,
               action: :get_by_sku,
               fail_on_not_found?: false
             )
  end

  test "ash_generic runs a real generic action through the generated clause" do
    assert {:ok, "PIVOT"} =
             run_op(:ash_generic, %{input: %{text: "pivot"}}, resource: Item, action: :shout)
  end

  test "ash_load runs a real calculation load through the generated clause" do
    {:ok, item} = Ash.create(Ash.Changeset.for_create(Item, :place, %{sku: "L1"}))

    assert {:ok, [loaded]} =
             run_op(:ash_load, %{records: [item], load: [:shouted_sku]}, resource: Item)

    assert loaded.shouted_sku == "L1"
    assert loaded.id == item.id
  end

  test "ash_step runs a real anonymous fun with notification enqueueing" do
    assert {:ok, :stepped} =
             run_op(:ash_step, %{}, run: fn _args, _ctx -> {:ok, :stepped} end)
  end

  test "bulk_create runs a real bulk create through the generated clause" do
    inputs = [%{sku: "B1"}, %{sku: "B2"}, %{sku: "B3"}]

    assert {:ok, %Ash.BulkResult{status: :success, records: records}} =
             run_op(:bulk_create, %{initial: inputs},
               resource: Item,
               action: :place,
               return_records?: true,
               notify?: false
             )

    assert length(records) == 3
    assert Enum.map(Enum.sort_by(records, & &1.sku), & &1.sku) == ["B1", "B2", "B3"]

    # Real post-state: the records are actually in the ETS table.
    assert {:ok, all} = Ash.read(Item |> Ash.Query.for_read(:read))
    assert length(all) == 3
  end
end
