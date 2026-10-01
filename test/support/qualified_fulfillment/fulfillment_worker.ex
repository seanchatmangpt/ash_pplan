defmodule AshPPlan.Test.FulfillmentWorker do
  @moduledoc """
  Real supervised, restartable worker process. Registered under a name so
  availability is observable via `Process.whereis/1`; `start_count/1` survives
  restarts through an Agent-free counter kept in `:persistent_term`-free ETS.
  """
  use GenServer

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    %{id: name, start: {__MODULE__, :start_link, [opts]}, restart: :permanent, type: :worker}
  end

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def ping(name \\ __MODULE__), do: GenServer.call(name, :ping)
  def starts(name \\ __MODULE__), do: GenServer.call(name, :starts)

  @impl true
  def init(opts) do
    counter = Keyword.get(opts, :counter) || :counters.new(1, [])
    :counters.add(counter, 1, 1)
    {:ok, %{counter: counter}}
  end

  @impl true
  def handle_call(:ping, _from, s), do: {:reply, :pong, s}
  def handle_call(:starts, _from, s), do: {:reply, :counters.get(s.counter, 1), s}
end
