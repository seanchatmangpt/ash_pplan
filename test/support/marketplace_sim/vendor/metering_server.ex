defmodule Vendor.MeteringServer do
  @moduledoc """
  Marketplace-sim metering server: per-entitlement usage aggregation.

  Dedupes usage events by `(entitlement_id, usage_event_id)`. Aggregates over
  a half-open window `[from_ts, to_ts)`. All timestamps are passed in as
  arguments — never taken from `:erlang.system_time/0` — so the court can pin
  them deterministically.
  """

  use GenServer

  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Records a usage event. Duplicate `(entitlement_id, usage_event_id)` pairs
  return `{:ok, :duplicate}` and are not counted again.
  """
  def post_usage(server \\ @name, entitlement_id, usage_event_id, metric, amount, ts) do
    GenServer.call(server, {:post_usage, entitlement_id, usage_event_id, metric, amount, ts})
  end

  @doc """
  Sums usage for `entitlement_id` over the half-open window `[{from_ts, to_ts}]` —
  events with `ts == to_ts` are excluded.
  """
  def aggregate(server \\ @name, entitlement_id, window) do
    GenServer.call(server, {:aggregate, entitlement_id, window})
  end

  @doc "Full per-entitlement totals, for court inspection."
  def totals(server \\ @name) do
    GenServer.call(server, :totals)
  end

  @impl true
  def init(_opts) do
    {:ok, %{events: %{}, seen: MapSet.new()}}
  end

  @impl true
  def handle_call({:post_usage, ent, event_id, metric, amount, ts}, _from, state) do
    key = {ent, event_id}

    if MapSet.member?(state.seen, key) do
      {:reply, {:ok, :duplicate}, state}
    else
      event = %{metric: metric, amount: amount, ts: ts}
      events = Map.update(state.events, ent, [event], &[event | &1])
      {:reply, {:ok, :recorded}, %{state | events: events, seen: MapSet.put(state.seen, key)}}
    end
  end

  def handle_call({:aggregate, ent, {from_ts, to_ts}}, _from, state) do
    total =
      state.events
      |> Map.get(ent, [])
      |> Enum.filter(fn %{ts: ts} -> ts >= from_ts and ts < to_ts end)
      |> Enum.map(& &1.amount)
      |> Enum.sum()

    {:reply, {:ok, total}, state}
  end

  def handle_call(:totals, _from, state) do
    totals =
      Map.new(state.events, fn {ent, events} ->
        {ent, events |> Enum.map(& &1.amount) |> Enum.sum()}
      end)

    {:reply, {:ok, totals}, state}
  end
end
