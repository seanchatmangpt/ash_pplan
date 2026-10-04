defmodule Vendor.Billing do
  @moduledoc """
  Marketplace-sim billing: EDP committed-spend drawdown over real shared
  ETS state. All amounts are integer cents.
  """

  @table :vendor_billing_edp
  @refs_table :vendor_billing_refs

  def start do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    if :ets.whereis(@refs_table) == :undefined do
      :ets.new(@refs_table, [:named_table, :public, :set])
    end

    :ok
  end

  @doc "Commits `committed_amount` cents of spend to `pool_id`."
  @spec allocate(term(), pos_integer()) :: :ok
  def allocate(pool_id, committed_amount)
      when is_integer(committed_amount) and committed_amount > 0 do
    start()
    :ets.insert(@table, {pool_id, committed_amount, 0})
    :ok
  end

  @doc """
  Draws `amount` cents against `pool_id`. Idempotent by `ref`: a repeated ref
  returns `{:ok, :duplicate}` without a second drawdown. Refuses draws beyond
  the committed amount with `{:error, {:overdraw, requested, remaining}}`.
  """
  @spec record(term(), pos_integer(), term()) ::
          {:ok, :recorded}
          | {:ok, :duplicate}
          | {:error, {:overdraw, integer(), integer()}}
          | {:error, :unknown_pool}
  def record(pool_id, amount, ref) when is_integer(amount) and amount > 0 do
    start()

    case :ets.lookup(@table, pool_id) do
      [] ->
        {:error, :unknown_pool}

      [{^pool_id, committed, spent}] ->
        if :ets.member(@refs_table, {pool_id, ref}) do
          {:ok, :duplicate}
        else
          remaining = committed - spent

          if amount > remaining do
            {:error, {:overdraw, amount, remaining}}
          else
            :ets.insert(@table, {pool_id, committed, spent + amount})
            :ets.insert(@refs_table, {{pool_id, ref}, true})
            {:ok, :recorded}
          end
        end
    end
  end

  @doc "Returns `{committed, spent, remaining}` in cents for `pool_id`."
  @spec balance(term()) :: {:ok, {integer(), integer(), integer()}} | {:error, :unknown_pool}
  def balance(pool_id) do
    case :ets.lookup(@table, pool_id) do
      [] -> {:error, :unknown_pool}
      [{^pool_id, committed, spent}] -> {:ok, {committed, spent, committed - spent}}
    end
  end
end
