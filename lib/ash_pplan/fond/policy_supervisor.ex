defmodule AshPPlan.FOND.PolicySupervisor do
  @moduledoc """
  Pure-data supervision for a portfolio of FOND policies.

  The supervisor validates candidates, deterministically selects the strongest
  admitted semantics, projects the next policy action as an intent, and consumes
  observed nondeterministic outcomes. It never executes an action and carries no
  Ash/Reactor/Oban authority.

  Preference is `:strong` before `:strong_cyclic`, then bounded cost, then a
  stable candidate identity. Observation advances an epoch so stale observations
  cannot mutate a newer selection.
  """

  alias AshPPlan.FOND

  @enforce_keys [:domain, :state, :portfolio, :epoch]
  defstruct [:domain, :state, :portfolio, :selected, :epoch, history: []]

  @type candidate :: %{
          required(:id) => term(),
          required(:policy) => FOND.policy(),
          required(:mode) => FOND.mode(),
          optional(:cost) => number(),
          optional(:authority) => term()
        }

  @type t :: %__MODULE__{
          domain: FOND.t(),
          state: FOND.state(),
          portfolio: [candidate()],
          selected: candidate() | nil,
          epoch: non_neg_integer(),
          history: [map()]
        }

  @doc "Creates a supervisor and selects the best policy admitted from initial."
  @spec new(FOND.t(), FOND.state(), [candidate()]) :: {:ok, t()} | {:error, term()}
  def new(%FOND{} = domain, initial, portfolio) when is_list(portfolio) do
    with {:ok, candidates} <- normalize_portfolio(portfolio),
         {:ok, selected} <- select(domain, initial, candidates) do
      {:ok,
       %__MODULE__{
         domain: domain,
         state: initial,
         portfolio: candidates,
         selected: selected,
         epoch: 0
       }}
    end
  end

  def new(domain, initial, portfolio),
    do: {:error, {:invalid_supervision_request, domain, initial, portfolio}}

  @doc "Returns a powerless action intent for the currently selected policy."
  @spec intent(t()) :: {:ok, map()} | {:error, term()}
  def intent(%__MODULE__{selected: nil}), do: {:error, :no_selected_policy}

  def intent(%__MODULE__{} = supervisor) do
    if MapSet.member?(supervisor.domain.goals, supervisor.state) do
      {:ok,
       %{
         kind: :goal,
         state: supervisor.state,
         policy_id: supervisor.selected.id,
         epoch: supervisor.epoch,
         authority: :none
       }}
    else
      case Map.fetch(supervisor.selected.policy, supervisor.state) do
        {:ok, action} ->
          {:ok,
           %{
             kind: :action_intent,
             state: supervisor.state,
             action: action,
             policy_id: supervisor.selected.id,
             semantics: supervisor.selected.mode,
             epoch: supervisor.epoch,
             authority: :none
           }}

        :error ->
          {:error, {:missing_selected_policy_action, supervisor.selected.id, supervisor.state}}
      end
    end
  end

  @doc """
  Admits an observed nondeterministic outcome and reselects a policy.

  The caller must present the epoch from the intent it is observing. This fences
  delayed observations after a prior transition or portfolio replacement.
  """
  @spec observe(t(), non_neg_integer(), FOND.state()) :: {:ok, t()} | {:error, term()}
  def observe(%__MODULE__{} = supervisor, epoch, outcome) do
    with :ok <- require_epoch(supervisor, epoch),
         {:ok, action} <- selected_action(supervisor),
         :ok <- admit_outcome(supervisor.domain, supervisor.state, action, outcome),
         {:ok, selected} <- select(supervisor.domain, outcome, supervisor.portfolio) do
      event = %{
        from: supervisor.state,
        action: action,
        outcome: outcome,
        policy_id: supervisor.selected.id,
        epoch: epoch
      }

      {:ok,
       %{
         supervisor
         | state: outcome,
           selected: selected,
           epoch: epoch + 1,
           history: [event | supervisor.history]
       }}
    end
  end

  @doc """
  Replaces the candidate portfolio and deterministically reselects at current state.

  Portfolio replacement increments the epoch, invalidating observations emitted
  from the previous selection.
  """
  @spec replace_portfolio(t(), [candidate()]) :: {:ok, t()} | {:error, term()}
  def replace_portfolio(%__MODULE__{} = supervisor, portfolio) when is_list(portfolio) do
    with {:ok, candidates} <- normalize_portfolio(portfolio),
         {:ok, selected} <- select(supervisor.domain, supervisor.state, candidates) do
      {:ok,
       %{
         supervisor
         | portfolio: candidates,
           selected: selected,
           epoch: supervisor.epoch + 1
       }}
    end
  end

  @doc "Returns admitted candidates in deterministic preference order."
  @spec admitted(FOND.t(), FOND.state(), [candidate()]) :: [candidate()]
  def admitted(%FOND{} = domain, initial, portfolio) do
    portfolio
    |> Enum.filter(&admitted_candidate?(domain, initial, &1))
    |> Enum.sort_by(&rank/1)
  end

  defp select(domain, initial, portfolio) do
    case admitted(domain, initial, portfolio) do
      [selected | _] -> {:ok, selected}
      [] -> {:error, {:no_admissible_policy, initial}}
    end
  end

  defp admitted_candidate?(domain, initial, candidate) do
    candidate.authority == :none and
      match?({:ok, _}, FOND.validate_policy(domain, candidate.policy, initial, candidate.mode))
  end

  defp normalize_portfolio(portfolio) do
    portfolio
    |> Enum.reduce_while({:ok, []}, fn candidate, {:ok, acc} ->
      case normalize_candidate(candidate) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, candidates} -> {:ok, Enum.reverse(candidates)}
      error -> error
    end
  end

  defp normalize_candidate(%{id: id, policy: policy, mode: mode} = candidate)
       when is_map(policy) and mode in [:strong, :strong_cyclic] do
    authority = Map.get(candidate, :authority, :none)
    cost = Map.get(candidate, :cost, 0)

    cond do
      authority != :none -> {:error, {:authority_bearing_candidate, id}}
      not is_number(cost) -> {:error, {:invalid_candidate_cost, id, cost}}
      true -> {:ok, %{id: id, policy: policy, mode: mode, cost: cost, authority: :none}}
    end
  end

  defp normalize_candidate(candidate), do: {:error, {:invalid_policy_candidate, candidate}}

  defp rank(candidate) do
    semantics = if candidate.mode == :strong, do: 0, else: 1
    {semantics, candidate.cost, stable_identity(candidate.id)}
  end

  defp stable_identity(id), do: :erlang.term_to_binary(id)

  defp require_epoch(%__MODULE__{epoch: epoch}, epoch), do: :ok
  defp require_epoch(%__MODULE__{epoch: current}, observed),
    do: {:error, {:stale_observation, observed, current}}

  defp selected_action(%__MODULE__{selected: nil}), do: {:error, :no_selected_policy}

  defp selected_action(%__MODULE__{} = supervisor) do
    case Map.fetch(supervisor.selected.policy, supervisor.state) do
      {:ok, action} -> {:ok, action}
      :error -> {:error, {:missing_selected_policy_action, supervisor.selected.id, supervisor.state}}
    end
  end

  defp admit_outcome(domain, state, action, outcome) do
    admitted = FOND.outcomes(domain, state, action)

    if outcome in admitted do
      :ok
    else
      {:error, {:unadmitted_outcome, state, action, outcome, admitted}}
    end
  end
end
