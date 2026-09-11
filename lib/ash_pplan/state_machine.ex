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
      deprecated_states = apply(@info_module, :state_machine_deprecated_states, [resource])
      transitions = apply(@info_module, :state_machine_transitions, [resource])

      wildcard_states = states -- deprecated_states

      wildcard_actions =
        resource
        |> Ash.Resource.Info.actions()
        |> Enum.filter(&(&1.type == :update))
        |> Enum.map(& &1.name)
        |> Enum.uniq()
        |> Enum.sort()

      from_transitions(states, transitions, goals,
        wildcard_states: wildcard_states,
        wildcard_actions: wildcard_actions
      )
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

  Direct projections treat every admitted state as wildcard-eligible. Use
  `from_transitions/4` to provide AshStateMachine's narrower wildcard-state
  universe and the concrete update-action universe used to expand `action: :*`.
  """
  @spec from_transitions([term()], [map()], term()) :: {:ok, FOND.t()} | {:error, map()}
  def from_transitions(states, transitions, goals \\ []) do
    from_transitions(states, transitions, goals, wildcard_states: states, wildcard_actions: [])
  end

  @doc """
  Projects transitions with explicit wildcard universes.

  AshStateMachine excludes deprecated states from `from: :*` and `to: :*`, but
  explicit references to a deprecated state remain legal. `action: :*` means
  every concrete update action on the resource, so a pure-data projection must
  provide those actions with `:wildcard_actions` rather than inventing them.
  """
  @spec from_transitions([term()], [map()], term(), keyword()) ::
          {:ok, FOND.t()} | {:error, map()}
  def from_transitions(states, transitions, goals, opts)
      when is_list(states) and is_list(transitions) and is_list(opts) do
    states = states |> Enum.uniq() |> Enum.sort()
    wildcard_states = opts |> Keyword.get(:wildcard_states, states) |> Enum.uniq() |> Enum.sort()
    wildcard_actions = opts |> Keyword.get(:wildcard_actions, []) |> Enum.uniq() |> Enum.sort()

    with :ok <- validate_state_set(states),
         :ok <- validate_wildcard_states(states, wildcard_states),
         :ok <- validate_wildcard_actions(wildcard_actions),
         {:ok, relation} <-
           build_relation(states, transitions, wildcard_states, wildcard_actions) do
      FOND.new(relation, goals)
    end
  end

  def from_transitions(states, transitions, _goals, opts),
    do:
      {:error,
       %{
         reason: :invalid_state_machine_projection,
         states: states,
         transitions: transitions,
         options: opts
       }}

  defp validate_state_set([]), do: {:error, %{reason: :empty_state_machine}}
  defp validate_state_set(_states), do: :ok

  defp validate_wildcard_states(states, wildcard_states) do
    unknown = Enum.reject(wildcard_states, &(&1 in states))

    if unknown == [] do
      :ok
    else
      {:error,
       %{reason: :unknown_wildcard_state, states: unknown |> Enum.uniq() |> Enum.sort()}}
    end
  end

  defp validate_wildcard_actions(wildcard_actions) do
    if :* in wildcard_actions do
      {:error, %{reason: :wildcard_action_must_be_concrete}}
    else
      :ok
    end
  end

  defp build_relation(states, transitions, wildcard_states, wildcard_actions) do
    seed = Map.new(states, &{&1, %{}})

    Enum.reduce_while(transitions, {:ok, seed}, fn transition, {:ok, relation} ->
      case normalize_transition(states, wildcard_states, wildcard_actions, transition) do
        {:ok, actions, from_states, to_states} ->
          relation =
            Enum.reduce(actions, relation, fn action, relation ->
              Enum.reduce(from_states, relation, fn from_state, relation ->
                Map.update!(relation, from_state, fn state_actions ->
                  Map.update(state_actions, action, to_states, fn existing ->
                    (existing ++ to_states) |> Enum.uniq() |> Enum.sort()
                  end)
                end)
              end)
            end)

          {:cont, {:ok, relation}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_transition(
         states,
         wildcard_states,
         wildcard_actions,
         %{action: action, from: from, to: to} = transition
       ) do
    actions = expand_actions(action, wildcard_actions)
    from_states = expand_states(from, wildcard_states)
    to_states = expand_states(to, wildcard_states)
    unknown = Enum.reject(from_states ++ to_states, &(&1 in states))

    cond do
      actions == [] ->
        {:error,
         %{
           reason: :wildcard_action_requires_actions,
           transition: transition
         }}

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
        {:ok, actions, from_states, to_states}
    end
  end

  defp normalize_transition(_states, _wildcard_states, _wildcard_actions, transition),
    do: {:error, %{reason: :invalid_state_machine_transition, transition: transition}}

  defp expand_actions(:*, wildcard_actions), do: wildcard_actions
  defp expand_actions(actions, _wildcard_actions) when is_list(actions), do: Enum.uniq(actions)
  defp expand_actions(action, _wildcard_actions), do: [action]

  defp expand_states(:*, wildcard_states), do: wildcard_states

  defp expand_states(values, wildcard_states) when is_list(values) do
    if :* in values do
      wildcard_states
    else
      values |> Enum.uniq() |> Enum.sort()
    end
  end

  defp expand_states(value, _wildcard_states), do: [value]
end
