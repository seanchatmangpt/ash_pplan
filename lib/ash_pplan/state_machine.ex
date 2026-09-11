defmodule AshPPlan.StateMachine do
  @moduledoc """
  Adapts an existing `AshStateMachine` resource into FOND transition data.

  This module deliberately does not implement state transitions. Ash actions
  and `AshStateMachine` remain authoritative for persistent resource lifecycle
  changes. `ash_pplan` only observes the declared transition relation and turns
  it into planner input.

  The adapter can also consume transition maps directly, which keeps the core
  policy semantics independently testable. `from_resource/2` requires the
  downstream application to install `ash_state_machine`.
  """

  alias AshPPlan.FOND

  @info_module Module.concat(["AshStateMachine", "Info"])

  @doc "Projects one AshStateMachine resource's declared transitions into a FOND domain."
  @spec from_resource(module(), term()) :: {:ok, FOND.t()} | {:error, map()}
  def from_resource(resource, goals \\ []) when is_atom(resource) do
    if Code.ensure_loaded?(@info_module) do
      states = apply(@info_module, :state_machine_all_states, [resource])
      transitions = apply(@info_module, :state_machine_transitions, [resource])
      from_transitions(states, transitions, goals)
    else
      {:error,
       %{
         reason: :ash_state_machine_not_available,
         resource: resource,
         requirement: ~s(add {:ash_state_machine, "~> 0.2.13"} to the downstream application)
       }}
    end
  end

  @doc """
  Projects AshStateMachine-style transition declarations into a FOND domain.

  `from: :*` and `to: :*` are expanded against the admitted state set. An
  action wildcard is refused because a planner must select a concrete Ash
  action; `:*` is a validation convenience, not a selectable operation.
  """
  @spec from_transitions([term()], [map()], term()) :: {:ok, FOND.t()} | {:error, map()}
  def from_transitions(states, transitions, goals \\ [])
      when is_list(states) and is_list(transitions) do
    states = states |> Enum.uniq() |> Enum.sort()

    with :ok <- validate_state_set(states),
         {:ok, relation} <- build_relation(states, transitions) do
      FOND.new(relation, goals)
    end
  end

  def from_transitions(states, transitions, _goals),
    do: {:error, %{reason: :invalid_state_machine_projection, states: states, transitions: transitions}}

  defp validate_state_set([]), do: {:error, %{reason: :empty_state_machine}}
  defp validate_state_set(_states), do: :ok

  defp build_relation(states, transitions) do
    seed = Map.new(states, &{&1, %{}})

    Enum.reduce_while(transitions, {:ok, seed}, fn transition, {:ok, relation} ->
      case normalize_transition(states, transition) do
        {:ok, action, from_states, to_states} ->
          relation =
            Enum.reduce(from_states, relation, fn from_state, relation ->
              Map.update!(relation, from_state, fn actions ->
                Map.update(actions, action, to_states, fn existing ->
                  (existing ++ to_states) |> Enum.uniq() |> Enum.sort()
                end)
              end)
            end)

          {:cont, {:ok, relation}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_transition(states, %{action: :*} = transition) do
    {:error, %{reason: :wildcard_action_not_plannable, transition: transition, states: states}}
  end

  defp normalize_transition(states, %{action: action, from: from, to: to} = transition) do
    from_states = expand_states(from, states)
    to_states = expand_states(to, states)
    unknown = Enum.reject(from_states ++ to_states, &(&1 in states))

    cond do
      from_states == [] ->
        {:error, %{reason: :empty_transition_source, transition: transition}}

      to_states == [] ->
        {:error, %{reason: :empty_transition_target, transition: transition}}

      unknown != [] ->
        {:error,
         %{
           reason: :unknown_state_in_transition,
           transition: transition,
           states: unknown |> Enum.uniq() |> Enum.sort()
         }}

      true ->
        {:ok, action, from_states, to_states}
    end
  end

  defp normalize_transition(_states, transition),
    do: {:error, %{reason: :invalid_state_machine_transition, transition: transition}}

  defp expand_states(:*, states), do: states

  defp expand_states(values, states) when is_list(values) do
    if :* in values do
      states
    else
      values |> Enum.uniq() |> Enum.sort()
    end
  end

  defp expand_states(value, _states), do: [value]
end
