defmodule AshPPlan.Reactor.Durable.Clock do
  @moduledoc """
  Injectable time. Production uses the system clock; tests install a controllable clock with
  `use_test_clock/1` so deadlines are crossed by `advance/1`, never by sleeping.
  """

  @key {__MODULE__, :now_fun}

  @spec now() :: DateTime.t()
  def now do
    case :persistent_term.get(@key, nil) do
      nil -> DateTime.utc_now()
      agent -> Agent.get(agent, & &1)
    end
  end

  @doc "Install a test clock starting at `start` (default: now). Returns the agent pid."
  @spec use_test_clock(DateTime.t()) :: pid()
  def use_test_clock(start \\ DateTime.utc_now()) do
    {:ok, pid} = Agent.start_link(fn -> start end)
    :persistent_term.put(@key, pid)
    pid
  end

  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  @spec advance(non_neg_integer()) :: DateTime.t()
  def advance(ms) do
    case :persistent_term.get(@key, nil) do
      nil ->
        raise ArgumentError, "no test clock installed"

      agent ->
        Agent.get_and_update(agent, fn t ->
          n = DateTime.add(t, ms, :millisecond)
          {n, n}
        end)
    end
  end

  @spec add(DateTime.t(), non_neg_integer()) :: DateTime.t()
  def add(%DateTime{} = t, ms), do: DateTime.add(t, ms, :millisecond)
end
