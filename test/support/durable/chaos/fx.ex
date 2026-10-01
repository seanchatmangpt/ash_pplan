defmodule AshPPlan.Test.Chaos.Counter do
  @moduledoc """
  Per-scenario effect counter: an unnamed `Agent` that outlives every simulated crash. Steps hold
  its pid in their options (data), so each scenario owns an isolated counter and no atom is minted.
  """

  @spec start_link() :: Agent.on_start()
  def start_link, do: Agent.start_link(fn -> %{} end)

  @doc "Bump `key`; returns the new count."
  @spec bump(pid(), term()) :: pos_integer()
  def bump(pid, key),
    do:
      Agent.get_and_update(pid, fn m ->
        n = Map.get(m, key, 0) + 1
        {n, Map.put(m, key, n)}
      end)

  @spec all(pid()) :: map()
  def all(pid), do: Agent.get(pid, & &1)

  @doc "Counts of consequential effects only (keys shaped `{:t, index}`), poll checks excluded."
  @spec effects(pid()) :: %{{:t, non_neg_integer()} => pos_integer()}
  def effects(pid), do: pid |> all() |> Map.filter(fn {k, _} -> match?({:t, _}, k) end)
end

defmodule AshPPlan.Test.Chaos.Effect do
  @moduledoc "Counting effect step for chaos workflows; `options[:effect]` is the counter key."
  use Reactor.Step

  @impl true
  def run(_arguments, _context, options) do
    effect = Keyword.fetch!(options, :effect)
    n = AshPPlan.Test.Chaos.Counter.bump(Keyword.fetch!(options, :effects), effect)
    {:ok, {effect, n}}
  end
end

defmodule AshPPlan.Test.Chaos.Cond do
  @moduledoc "Poll condition for chaos workflows: satisfied from the `k`th+1 check onward."

  @spec ready(map(), map(), pid(), non_neg_integer(), non_neg_integer()) ::
          {:ok, :ready} | :not_yet
  def ready(_arguments, _context, counter, index, k) do
    if AshPPlan.Test.Chaos.Counter.bump(counter, {:poll, index}) > k,
      do: {:ok, :ready},
      else: :not_yet
  end
end

defmodule AshPPlan.Test.Chaos.Adapter do
  @moduledoc "Test adapter mapping chaos ops to counting, Await and Poll steps."
  @behaviour AshPPlan.Reactor.Adapter

  alias AshPPlan.Reactor.Durable.Steps
  alias AshPPlan.Test.Chaos.Effect

  @impl true
  def id, do: :chaos_fx
  @impl true
  def available?, do: true
  @impl true
  def ops, do: [:count, :await, :poll]

  @impl true
  def step(op, options) do
    table = %{
      count: {Effect, []},
      await: {Steps.Await, [timeout: nil]},
      poll: {Steps.Poll, []}
    }

    AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
  end
end
