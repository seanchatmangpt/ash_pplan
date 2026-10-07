defmodule AshPPlan.StateMachine do
  @moduledoc """
  Projects `AshStateMachine` lifecycle semantics into planner data.

  `ash_state_machine` is a first-class dependency of `ash_pplan`, so this adapter
  deliberately calls its public modules directly. Contract drift should fail at
  compile time instead of being hidden behind dynamic dispatch.

  This module never performs a state transition. `AshStateMachine`, Ash actions,
  and Ash policies remain authoritative for persistent resource lifecycle
  changes. The projection exposes lifecycle facts for planning without creating
  a second state-machine runtime.
  """

  alias AshPPlan.FOND

  @transition_change AshStateMachine.BuiltinChanges.TransitionState
  @next_state_change AshStateMachine.BuiltinChanges.NextState
  @valid_next_state_check AshStateMachine.Checks.ValidNextState

  @doc "Projects one AshStateMachine resource's declared transitions into a FOND domain."
  @spec from_resource(module(), term()) :: {:ok, FOND.t()} | {:error, map()}
  def from_resource(resource, goals \\ []) when is_atom(resource) do
    with {:ok, lifecycle} <- describe_resource(resource) do
      from_transitions(lifecycle.states, lifecycle.transitions, goals,
        wildcard_states: lifecycle.wildcard_states,
        wildcard_actions: lifecycle.wildcard_actions
      )
    end
  end

  @doc """
  Returns the resolved lifecycle surface declared by `AshStateMachine`.

  `states` contains every valid persisted state, including deprecated states.
  `wildcard_states` is deliberately narrower: it is the exact state universe
  manufactured by AshStateMachine for `:*`, which excludes deprecated-only
  states. Explicit references to deprecated states remain valid.
  """
  @spec describe_resource(module()) :: {:ok, map()} | {:error, map()}
  def describe_resource(resource) when is_atom(resource) do
    with :ok <- ensure_ash_resource(resource),
         :ok <- ensure_configured(resource) do
      wildcard_states =
        resource
        |> AshStateMachine.Info.state_machine_all_states()
        |> normalize_terms()

      deprecated_states =
        resource
        |> AshStateMachine.Info.state_machine_deprecated_states!()
        |> normalize_terms()

      transitions =
        resource
        |> AshStateMachine.Info.state_machine_transitions()
        |> Enum.map(&transition_descriptor/1)

      wildcard_actions = update_actions(resource)

      {:ok,
       %{
         owner: AshStateMachine,
         resource: resource,
         state_attribute: AshStateMachine.Info.state_machine_state_attribute!(resource),
         states: normalize_terms(wildcard_states ++ deprecated_states),
         wildcard_states: wildcard_states,
         deprecated_states: deprecated_states,
         extra_states:
           resource
           |> AshStateMachine.Info.state_machine_extra_states!()
           |> normalize_terms(),
         initial_states:
           resource
           |> AshStateMachine.Info.state_machine_initial_states!()
           |> normalize_terms(),
         default_initial_state: default_initial_state(resource),
         transitions: transitions,
         wildcard_actions: wildcard_actions,
         capabilities: capability_descriptor(resource, transitions, deprecated_states),
         authority: authority_descriptor()
       }}
    end
  end

  # Typed-refusal law: a non-atom "resource" is a typed rejection, never a
  # FunctionClauseError.
  def describe_resource(resource),
    do: {:error, %{reason: :not_an_ash_resource, resource: resource}}

  @doc """
  Returns only the resolved lifecycle capability descriptor.

  The descriptor separates upstream support from resource configuration:

    * `:supported` - what the installed `AshStateMachine` can do for any resource.
      These are facts about the dependency, never about this resource.
    * `:configured` - what this specific resource actually declares, derived from
      its transitions, action changes, policies and preparations.

  The flat boolean keys (`:policy_preflight?`, `:wildcard_transitions?`, ...)
  mirror `:configured`. None of them is ever claimed from extension presence
  alone. Because AshStateMachine expands `from: :*`/`to: :*` into concrete state
  lists at compile time, `:wildcard_transitions?` observes `action: :*` only.
  """
  @spec capabilities(module()) :: {:ok, map()} | {:error, map()}
  def capabilities(resource) when is_atom(resource) do
    with {:ok, lifecycle} <- describe_resource(resource) do
      {:ok, lifecycle.capabilities}
    end
  end

  def capabilities(resource), do: {:error, %{reason: :not_an_ash_resource, resource: resource}}

  @doc """
  Delegates possible-next-state observation to AshStateMachine for every action,
  without mutating the record.
  """
  @spec possible_next_states(struct()) :: {:ok, [atom()]} | {:error, map()}
  def possible_next_states(%resource{} = record) do
    with :ok <- ensure_ash_resource(resource),
         :ok <- ensure_configured(resource) do
      {:ok, AshStateMachine.possible_next_states(record)}
    end
  end

  def possible_next_states(record),
    do: {:error, %{reason: :invalid_state_machine_record, record: record}}

  @doc """
  Delegates possible-next-state observation for one concrete Ash action.

  `action` is always an action name, including an action literally named
  `:all`; use `possible_next_states/1` for the every-action view. Unknown or
  non-atom actions are refused rather than silently answered with `[]`.
  """
  @spec possible_next_states(struct(), atom()) :: {:ok, [atom()]} | {:error, map()}
  def possible_next_states(%resource{} = record, action) when is_atom(action) do
    with :ok <- ensure_ash_resource(resource),
         :ok <- ensure_configured(resource),
         :ok <- ensure_action(resource, action) do
      {:ok, AshStateMachine.possible_next_states(record, action)}
    end
  end

  def possible_next_states(%_{} = _record, action),
    do: {:error, %{reason: :invalid_state_machine_action, action: action}}

  def possible_next_states(record, _action),
    do: {:error, %{reason: :invalid_state_machine_record, record: record}}

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

  Goals must be drawn from the admitted lifecycle state set; a goal naming an
  undeclared state is refused with `:unknown_goal_states` instead of producing
  an unreachable FOND goal.

  AshStateMachine excludes deprecated-only states from `from: :*` and `to: :*`,
  while explicit references to deprecated states remain legal. `action: :*`
  means every concrete update action on the resource, so a pure-data projection
  must provide those actions with `:wildcard_actions` rather than inventing them.
  """
  @spec from_transitions([term()], [map()], term(), keyword()) ::
          {:ok, FOND.t()} | {:error, map()}
  def from_transitions(states, transitions, goals, opts)
      when is_list(states) and is_list(transitions) and is_list(opts) do
    states = normalize_terms(states)
    wildcard_states = opts |> Keyword.get(:wildcard_states, states) |> normalize_terms()
    wildcard_actions = opts |> Keyword.get(:wildcard_actions, []) |> normalize_terms()

    with :ok <- validate_state_set(states),
         {:ok, goals} <- validate_goals(states, goals),
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

  defp ensure_ash_resource(resource) do
    if Spark.Dsl.is?(resource, Ash.Resource) do
      :ok
    else
      {:error, %{reason: :not_an_ash_resource, resource: resource}}
    end
  end

  defp ensure_configured(resource) do
    if AshStateMachine in Spark.extensions(resource) do
      :ok
    else
      {:error,
       %{
         reason: :ash_state_machine_not_configured,
         resource: resource,
         extension: AshStateMachine
       }}
    end
  end

  defp ensure_action(resource, action) do
    if Ash.Resource.Info.action(resource, action) do
      :ok
    else
      {:error, %{reason: :unknown_state_machine_action, resource: resource, action: action}}
    end
  end

  defp default_initial_state(resource) do
    case AshStateMachine.Info.state_machine_default_initial_state(resource) do
      {:ok, state} -> state
      :error -> nil
    end
  end

  defp update_actions(resource) do
    resource
    |> Ash.Resource.Info.actions()
    |> Enum.filter(&(&1.type == :update))
    |> Enum.map(& &1.name)
    |> normalize_terms()
  end

  defp transition_descriptor(transition) do
    %{
      action: transition.action,
      from: normalize_terms(transition.from),
      to: normalize_terms(transition.to)
    }
  end

  @supported %{
    atomic_transition?: true,
    create_initial_state?: true,
    upsert_transition?: true,
    next_state_change?: true,
    policy_preflight?: true,
    possible_next_states?: true,
    state_always_selected?: true,
    wildcard_transitions?: true,
    deprecated_states?: true,
    diagrams?: true
  }

  defp capability_descriptor(resource, transitions, deprecated_states) do
    actions = Ash.Resource.Info.actions(resource)
    transition_actions = transitions |> Enum.map(& &1.action) |> MapSet.new()

    configured = %{
      atomic_transition?:
        Enum.any?(
          actions,
          &(&1.type == :update and uses_change?(resource, &1, @transition_change))
        ),
      create_initial_state?:
        Enum.any?(actions, &(&1.type == :create)) and
          (default_initial_state(resource) != nil or
             Enum.any?(
               actions,
               &(&1.type == :create and uses_change?(resource, &1, @transition_change))
             )),
      upsert_transition?:
        Enum.any?(
          actions,
          &(&1.type == :create and Map.get(&1, :upsert?, false) and
              MapSet.member?(transition_actions, &1.name))
        ),
      next_state_change?: Enum.any?(actions, &uses_change?(resource, &1, @next_state_change)),
      policy_preflight?: valid_next_state_policy?(resource),
      possible_next_states?: transitions != [],
      state_always_selected?: state_always_selected?(resource),
      wildcard_transitions?: MapSet.member?(transition_actions, :*),
      deprecated_states_configured?: deprecated_states != [],
      diagrams?: transitions != []
    }

    Map.merge(configured, %{supported: @supported, configured: configured})
  end

  defp uses_change?(resource, action, module) do
    resource
    |> Ash.Resource.Info.action_changes(action)
    |> Enum.any?(fn
      %Ash.Resource.Change{change: {^module, _opts}} -> true
      _other -> false
    end)
  end

  defp valid_next_state_policy?(resource) do
    resource
    |> Ash.Policy.Info.policies()
    |> Enum.flat_map(&List.wrap(&1.policies))
    |> Enum.any?(&match?(%Ash.Policy.Check{check_module: @valid_next_state_check}, &1))
  end

  # Observes the preparation AshStateMachine actually registered. Only a plain
  # attribute name in `ensure_selected` selects the state; a malformed entry
  # (e.g. `{:ok, :state}`) is not evidence that the state is always selected.
  defp state_always_selected?(resource) do
    attribute = AshStateMachine.Info.state_machine_state_attribute!(resource)

    resource
    |> Ash.Resource.Info.preparations()
    |> Enum.any?(fn
      %{preparation: {Ash.Resource.Preparation.Build, opts}} ->
        attribute in List.wrap(opts[:ensure_selected])

      _other ->
        false
    end)
  end

  defp authority_descriptor do
    %{
      inspect: AshStateMachine.Info,
      mutate: AshStateMachine,
      policy_check: AshStateMachine.Checks.ValidNextState,
      transition_change: AshStateMachine.BuiltinChanges.TransitionState,
      next_state_change: AshStateMachine.BuiltinChanges.NextState,
      diagrams: AshStateMachine.Charts
    }
  end

  defp normalize_terms(terms), do: terms |> List.wrap() |> Enum.uniq() |> Enum.sort()

  defp validate_state_set([]), do: {:error, %{reason: :empty_state_machine}}
  defp validate_state_set(_states), do: :ok

  defp validate_goals(states, goals) do
    if Enumerable.impl_for(goals) do
      goals = normalize_terms(Enum.to_list(goals))

      case Enum.reject(goals, &(&1 in states)) do
        [] -> {:ok, goals}
        unknown -> {:error, %{reason: :unknown_goal_states, states: unknown}}
      end
    else
      {:error, %{reason: :invalid_goal_states, goals: goals}}
    end
  end

  defp validate_wildcard_states(states, wildcard_states) do
    unknown = Enum.reject(wildcard_states, &(&1 in states))

    if unknown == [] do
      :ok
    else
      {:error, %{reason: :unknown_wildcard_state, states: normalize_terms(unknown)}}
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
                  case Map.fetch(state_actions, action) do
                    :error -> Map.put(state_actions, action, to_states)
                    {:ok, existing} -> Map.put(state_actions, action, normalize_terms(existing ++ to_states))
                  end
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
        {:error, %{reason: :wildcard_action_requires_actions, transition: transition}}

      from_states == [] ->
        {:error, %{reason: :empty_transition_source, transition: transition}}

      to_states == [] ->
        {:error, %{reason: :empty_transition_target, transition: transition}}

      unknown != [] ->
        {:error,
         %{
           reason: :unknown_state_in_transition,
           transition: transition,
           states: normalize_terms(unknown)
         }}

      true ->
        {:ok, actions, from_states, to_states}
    end
  end

  defp normalize_transition(_states, _wildcard_states, _wildcard_actions, transition),
    do: {:error, %{reason: :invalid_state_machine_transition, transition: transition}}

  defp expand_actions(:*, wildcard_actions), do: wildcard_actions

  defp expand_actions(actions, _wildcard_actions) when is_list(actions) do
    if :* in actions do
      []
    else
      normalize_terms(actions)
    end
  end

  defp expand_actions(action, _wildcard_actions), do: [action]

  defp expand_states(:*, wildcard_states), do: wildcard_states

  defp expand_states(values, wildcard_states) when is_list(values) do
    if :* in values do
      wildcard_states
    else
      normalize_terms(values)
    end
  end

  defp expand_states(value, _wildcard_states), do: [value]
end
