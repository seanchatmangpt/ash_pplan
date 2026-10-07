defmodule AshPPlan.FOND do
  @moduledoc """
  Finite, fully observable nondeterministic policy semantics for `ash_pplan`.

  Reactor remains the executor. This module models the policy layer Reactor does
  not own: for a symbolic state and selected action, which successor states may
  the environment produce, and does a candidate policy reach a goal under
  strong or strong-cyclic semantics?

  A domain is pure data. `transitions` has the form:

      %{
        pending: %{attempt: [:pending, :succeeded]},
        succeeded: %{}
      }

  A policy maps every reachable non-goal state to one admitted action:

      %{pending: :attempt}

  `:strong` requires all executions to reach a goal without relying on fairness.
  `:strong_cyclic` permits retry cycles when every reachable policy state still
  has a path to a goal; this is the standard fairness assumption used for
  strong-cyclic FOND policies.
  """

  @enforce_keys [:states, :goals, :transitions]
  defstruct [:states, :goals, :transitions]

  @type state :: term()
  @type action :: term()
  @type mode :: :strong | :strong_cyclic
  @type policy :: %{optional(state()) => action()}
  @type t :: %__MODULE__{
          states: MapSet.t(state()),
          goals: MapSet.t(state()),
          transitions: %{optional(state()) => %{optional(action()) => [state()]}}
        }

  @doc """
  Builds a normalized FOND domain from a transition relation and goal states.

  `goals` must be a list or `MapSet`. Every nondeterministic outcome list must
  be non-empty: an action with no outcome is refused rather than admitted as a
  vacuous success.
  """
  @spec new(map(), [state()] | MapSet.t(state())) :: {:ok, t()} | {:error, map()}
  def new(transitions, goals \\ [])

  def new(transitions, goals) when is_map(transitions) do
    with {:ok, goals} <- normalize_goals(goals),
         {:ok, transitions} <- normalize_transitions(transitions) do
      states = collect_states(transitions, goals)

      {:ok, %__MODULE__{states: states, goals: goals, transitions: transitions}}
    end
  end

  def new(transitions, _goals),
    do: {:error, %{reason: :invalid_transition_relation, transitions: transitions}}

  @doc """
  Checks the invariants `new/2` establishes.

  `%AshPPlan.FOND{}` is a public struct, so a hand-built value can bypass
  `new/2`. Validation and synthesis admit a domain only when it is already in
  the normalized form `new/2` would produce: goals and states are `MapSet`s,
  every outcome list is non-empty, sorted and duplicate-free, and every state
  mentioned by the relation or the goals is a member of `states`.
  """
  @spec check(term()) :: :ok | {:error, map()}
  def check(
        %__MODULE__{
          states: %MapSet{} = states,
          goals: %MapSet{} = goals,
          transitions: transitions
        } =
          domain
      )
      when is_map(transitions) do
    cond do
      normalize_transitions(transitions) != {:ok, transitions} ->
        {:error, %{reason: :invalid_domain, detail: :unnormalized_transitions}}

      not MapSet.subset?(collect_states(transitions, goals), states) ->
        {:error,
         %{
           reason: :invalid_domain,
           detail: :undeclared_states,
           states: difference_sorted(collect_states(transitions, goals), domain.states)
         }}

      true ->
        :ok
    end
  end

  def check(_domain), do: {:error, %{reason: :invalid_domain, detail: :not_a_fond_domain}}

  @doc "Returns admitted actions for a state."
  @spec actions(t(), state()) :: [action()]
  def actions(%__MODULE__{transitions: transitions}, state) do
    transitions
    |> Map.get(state, %{})
    |> Map.keys()
    |> Enum.sort()
  end

  @doc "Returns all nondeterministic outcomes admitted for `state × action`."
  @spec outcomes(t(), state(), action()) :: [state()]
  def outcomes(%__MODULE__{transitions: transitions}, state, action) do
    transitions
    |> Map.get(state, %{})
    |> Map.get(action, [])
  end

  @doc """
  Validates a candidate policy from one initial state.

  Returns a receipt-like report containing the complete reachable policy state
  set when the candidate satisfies the requested semantics. It refuses
  malformed domains, policy entries for states outside the domain, actions
  that are not admitted in a state the policy reaches, missing policy
  decisions, and policies that cannot establish the requested goal guarantee.

  Entries for goal states or for states the policy never reaches cannot affect
  any verdict, so they are admitted but not silently approved: the report lists
  them under `:ignored_policy_states`.
  """
  @spec validate_policy(t(), policy(), state(), mode()) :: {:ok, map()} | {:error, map()}
  def validate_policy(domain, policy, initial, mode \\ :strong_cyclic)

  def validate_policy(%__MODULE__{} = domain, policy, initial, mode)
      when is_map(policy) and mode in [:strong, :strong_cyclic] do
    with :ok <- check(domain),
         :ok <- check_initial(domain, initial),
         :ok <- check_policy_entries(domain, policy),
         {:ok, reachable} <- reachable_under_policy(domain, policy, initial),
         {:ok, report} <- validate_mode(domain, policy, initial, reachable, mode) do
      {:ok,
       Map.put(report, :ignored_policy_states, ignored_policy_states(domain, policy, reachable))}
    end
  end

  def validate_policy(_domain, policy, initial, mode),
    do: {:error, %{reason: :invalid_policy_request, policy: policy, initial: initial, mode: mode}}

  @doc """
  Renders the domain under `policy` from `initial` as a TLA+ module and TLC
  config (render only: authority `NONE`, ceiling `CONSTRUCT`).

  `:strong` renders no fairness over outcomes; `:strong_cyclic` renders
  `SF_vars` over every outcome branch. TLC's verdict on `<>Goal` for the
  rendered model is expected to equal `validate_policy/4`'s verdict for the
  same arguments. See `AshPPlan.FOND.TLA` for the encoding.
  """
  @spec to_tla(t(), policy(), state(), mode(), keyword()) ::
          {:ok, AshPPlan.FOND.TLA.rendered()} | {:error, map()}
  def to_tla(domain, policy, initial, mode \\ :strong_cyclic, opts \\ []),
    do: AshPPlan.FOND.TLA.render(domain, policy, initial, mode, opts)

  defp check_initial(domain, initial) do
    if MapSet.member?(domain.states, initial),
      do: :ok,
      else: {:error, %{reason: :unknown_initial_state, state: initial}}
  end

  # A policy key that names no domain state is a typo (or a string/atom mixup),
  # not behaviour, so it is refused. Whether an entry's action is admitted is
  # decided only where the policy is actually followed: `reachable_under_policy`
  # refuses an unavailable action on a reachable state, and entries on goal or
  # unreachable states cannot change any verdict (the TLC and independent-reader
  # courts agree), so they are reported under `:ignored_policy_states` instead.
  defp check_policy_entries(domain, policy) do
    case policy |> Map.keys() |> Enum.reject(&MapSet.member?(domain.states, &1)) do
      [] -> :ok
      unknown -> {:error, %{reason: :unknown_policy_states, states: Enum.sort(unknown)}}
    end
  end

  defp ignored_policy_states(domain, policy, reachable) do
    policy
    |> Map.keys()
    |> Enum.filter(&(MapSet.member?(domain.goals, &1) or not MapSet.member?(reachable, &1)))
    |> Enum.sort()
  end

  defp normalize_goals(%MapSet{} = goals), do: {:ok, goals}
  defp normalize_goals(goals) when is_list(goals), do: {:ok, MapSet.new(goals)}
  defp normalize_goals(goals), do: {:error, %{reason: :invalid_goals, goals: goals}}

  defp normalize_transitions(transitions) do
    Enum.reduce_while(transitions, {:ok, %{}}, fn {state, actions}, {:ok, acc} ->
      if is_map(actions) do
        case normalize_actions(state, actions) do
          {:ok, actions} -> {:cont, {:ok, Map.put(acc, state, actions)}}
          {:error, error} -> {:halt, {:error, error}}
        end
      else
        {:halt, {:error, %{reason: :invalid_actions, state: state, actions: actions}}}
      end
    end)
  end

  defp normalize_actions(state, actions) do
    Enum.reduce_while(actions, {:ok, %{}}, fn {action, outcomes}, {:ok, acc} ->
      case normalize_outcomes(outcomes) do
        {:ok, []} ->
          {:halt,
           {:error, %{reason: :empty_nondeterministic_outcome, state: state, action: action}}}

        {:ok, outcomes} ->
          {:cont, {:ok, Map.put(acc, action, outcomes)}}

        :error ->
          {:halt,
           {:error, %{reason: :invalid_nondeterministic_outcomes, state: state, action: action}}}
      end
    end)
  end

  defp normalize_outcomes(%MapSet{} = outcomes),
    do: {:ok, outcomes |> MapSet.to_list() |> strict_sort()}

  defp normalize_outcomes(outcomes) when is_list(outcomes),
    do: {:ok, outcomes |> Enum.uniq() |> strict_sort()}

  defp normalize_outcomes(_outcomes), do: :error

  # Erlang term order treats `1` and `1.0` as equal, so a plain sort leaves
  # them in input order and the normalized domain would depend on how the
  # caller spelled it. Breaking ties on the external term format is a strict
  # total order over distinct terms.
  defp strict_sort(terms), do: Enum.sort_by(terms, &{&1, :erlang.term_to_binary(&1)})

  defp collect_states(transitions, goals) do
    Enum.reduce(transitions, goals, fn {state, actions}, states ->
      states = MapSet.put(states, state)

      Enum.reduce(actions, states, fn {_action, outcomes}, states ->
        Enum.reduce(outcomes, states, &MapSet.put(&2, &1))
      end)
    end)
  end

  defp reachable_under_policy(domain, policy, initial) do
    walk_reachable(domain, policy, :queue.from_list([initial]), MapSet.new())
  end

  # Breadth-first, so the first refused state is the one closest to `initial`.
  defp walk_reachable(domain, policy, queue, seen) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        {:ok, seen}

      {{:value, state}, queue} ->
        cond do
          MapSet.member?(seen, state) ->
            walk_reachable(domain, policy, queue, seen)

          MapSet.member?(domain.goals, state) ->
            walk_reachable(domain, policy, queue, MapSet.put(seen, state))

          true ->
            with {:ok, action} <- fetch_policy_action(policy, state),
                 {:ok, outcomes} <- fetch_action_outcomes(domain, state, action) do
              queue = Enum.reduce(outcomes, queue, &:queue.in/2)
              walk_reachable(domain, policy, queue, MapSet.put(seen, state))
            end
        end
    end
  end

  defp fetch_policy_action(policy, state) do
    case Map.fetch(policy, state) do
      {:ok, action} -> {:ok, action}
      :error -> {:error, %{reason: :missing_policy_action, state: state}}
    end
  end

  defp fetch_action_outcomes(domain, state, action) do
    case outcomes(domain, state, action) do
      [] ->
        {:error,
         %{
           reason: :unavailable_policy_action,
           state: state,
           action: action,
           available: actions(domain, state)
         }}

      outcomes ->
        {:ok, outcomes}
    end
  end

  defp validate_mode(domain, policy, initial, reachable, :strong) do
    winning = strong_winning(domain, policy, reachable)

    if MapSet.subset?(reachable, winning) do
      {:ok, policy_report(initial, reachable, :strong)}
    else
      {:error,
       %{
         reason: :not_strong,
         initial: initial,
         losing_states: difference_sorted(reachable, winning)
       }}
    end
  end

  defp validate_mode(domain, policy, initial, reachable, :strong_cyclic) do
    goal_reachable = goal_reaching(domain, policy, reachable)

    if MapSet.subset?(reachable, goal_reachable) do
      {:ok, policy_report(initial, reachable, :strong_cyclic)}
    else
      {:error,
       %{
         reason: :not_strong_cyclic,
         initial: initial,
         states_without_goal_path: difference_sorted(reachable, goal_reachable)
       }}
    end
  end

  # Both fixpoints run over the policy graph restricted to `reachable`, using a
  # predecessor index built once, so each is linear in the policy graph's
  # edges rather than rescanning every state per round.

  # Least fixpoint of `goals ∪ {s | every policy outcome of s is winning}`: a
  # state wins once its count of not-yet-winning successors reaches zero.
  defp strong_winning(domain, policy, reachable) do
    successors = policy_successors(domain, policy, reachable)
    predecessors = predecessor_index(successors)
    pending = Map.new(successors, fn {state, outcomes} -> {state, length(outcomes)} end)
    goals = reachable |> MapSet.intersection(domain.goals) |> MapSet.to_list()

    strong_worklist(goals, predecessors, pending, MapSet.new(goals))
  end

  defp strong_worklist([], _predecessors, _pending, winning), do: winning

  defp strong_worklist([state | rest], predecessors, pending, winning) do
    {queue, pending, winning} =
      predecessors
      |> Map.get(state, [])
      |> Enum.reduce({rest, pending, winning}, fn predecessor, {queue, pending, winning} ->
        if MapSet.member?(winning, predecessor) do
          {queue, pending, winning}
        else
          remaining = Map.fetch!(pending, predecessor) - 1
          pending = Map.put(pending, predecessor, remaining)

          if remaining == 0,
            do: {[predecessor | queue], pending, MapSet.put(winning, predecessor)},
            else: {queue, pending, winning}
        end
      end)

    strong_worklist(queue, predecessors, pending, winning)
  end

  # Backward reachability to the reachable goals along policy edges.
  defp goal_reaching(domain, policy, reachable) do
    predecessors = domain |> policy_successors(policy, reachable) |> predecessor_index()
    goals = reachable |> MapSet.intersection(domain.goals) |> MapSet.to_list()

    backward_worklist(goals, predecessors, MapSet.new(goals))
  end

  defp backward_worklist([], _predecessors, reached), do: reached

  defp backward_worklist([state | rest], predecessors, reached) do
    {queue, reached} =
      predecessors
      |> Map.get(state, [])
      |> Enum.reduce({rest, reached}, fn predecessor, {queue, reached} ->
        if MapSet.member?(reached, predecessor),
          do: {queue, reached},
          else: {[predecessor | queue], MapSet.put(reached, predecessor)}
      end)

    backward_worklist(queue, predecessors, reached)
  end

  defp policy_successors(domain, policy, reachable) do
    for state <- reachable, not MapSet.member?(domain.goals, state), into: %{} do
      {state, outcomes(domain, state, Map.fetch!(policy, state))}
    end
  end

  defp predecessor_index(successors) do
    Enum.reduce(successors, %{}, fn {state, outcomes}, index ->
      Enum.reduce(outcomes, index, fn outcome, index ->
        case Map.fetch(index, outcome) do
          :error -> Map.put(index, outcome, [state])
          {:ok, states} -> Map.put(index, outcome, [state | states])
        end
      end)
    end)
  end

  defp policy_report(initial, reachable, mode) do
    %{
      semantics: mode,
      initial: initial,
      reachable_states: reachable |> MapSet.to_list() |> Enum.sort(),
      reachable_count: MapSet.size(reachable)
    }
  end

  defp difference_sorted(left, right) do
    left
    |> MapSet.difference(right)
    |> MapSet.to_list()
    |> Enum.sort()
  end
end
