defmodule AshPPlan.ReactorOutcome do
  @moduledoc """
  Classifies Reactor's public execution results into planner observations.

  No execution authority lives here. Reactor produces the outcome; ash_pplan
  turns that outcome into a stable symbolic observation suitable for a FOND
  policy or receipt.
  """

  @type state :: :succeeded | :halted | :failed | :unknown

  @doc "Returns the symbolic planner state represented by a Reactor result."
  @spec state(term()) :: state()
  def state({:ok, _value}), do: :succeeded
  def state({:ok, _value, _reactor}), do: :succeeded
  def state({:halted, _reactor}), do: :halted
  def state({:error, _reason}), do: :failed
  def state(_other), do: :unknown

  @doc "Returns a bounded observation without claiming execution authority."
  @spec observe(term()) :: map()
  def observe({:ok, value}), do: %{state: :succeeded, value: value}
  def observe({:ok, value, reactor}), do: %{state: :succeeded, value: value, reactor: reactor}
  def observe({:halted, reactor}), do: %{state: :halted, reactor: reactor}
  def observe({:error, reason}), do: %{state: :failed, reason: reason}
  def observe(other), do: %{state: :unknown, outcome: other}
end
