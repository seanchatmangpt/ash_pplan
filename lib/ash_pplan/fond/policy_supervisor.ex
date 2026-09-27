defmodule AshPPlan.FOND.PolicySupervisor do
  @moduledoc "Pure-data FOND policy supervision. Produces intents; never actuates them."

  alias AshPPlan.FOND

  @enforce_keys [:domain, :initial, :state, :epoch, :portfolio, :selected]
  defstruct [:domain, :initial, :state, :epoch, :portfolio, :selected, history: []]

  @type candidate :: %{required(:id) => term(), required(:policy) => map(), required(:semantics) => :strong | :strong_cyclic, optional(:cost) => number(), optional(:authority) => boolean()}
  @type t :: %__MODULE__{}

  @spec start(FOND.t(), term(), [candidate()]) :: {:ok, t()} | {:error, map()}
  def start(%FOND{} = domain, initial, portfolio) when is_list(portfolio) do
    with {:ok, candidates} <- validate_portfolio(domain, initial, portfolio),
         {:ok, selected} <- choose(candidates) do
      {:ok, %__MODULE__{domain: domain, initial: initial, state: initial, epoch: 0, portfolio: candidates, selected: selected}}
    end
  end

  @spec intent(t()) :: {:ok, map()} | {:error, map()}
  def intent(%__MODULE__{domain: domain, state: state, selected: selected, epoch: epoch}) do
    if MapSet.member?(domain.goals, state) do
      {:ok, %{kind: :goal, state: state, epoch: epoch, authority: false}}
    else
      case Map.fetch(selected.policy, state) do
        {:ok, action} -> {:ok, %{kind: :action_intent, state: state, action: action, policy: selected.id, epoch: epoch, authority: false}}
        :error -> {:error, %{reason: :missing_selected_action, state: state, policy: selected.id}}
      end
    end
  end

  @spec observe(t(), non_neg_integer(), term()) :: {:ok, t()} | {:error, map()}
  def observe(%__MODULE__{epoch: epoch} = supervisor, epoch, outcome) do
    with {:ok, intent} <- intent(supervisor),
         :ok <- admit_outcome(supervisor.domain, intent, outcome) do
      next = %{supervisor | state: outcome, epoch: epoch + 1, history: [{epoch, intent, outcome} | supervisor.history]}
      reselect(next)
    end
  end

  def observe(%__MODULE__{epoch: expected}, observed, outcome),
    do: {:error, %{reason: :stale_observation, expected_epoch: expected, observed_epoch: observed, outcome: outcome}}

  @spec reselect(t()) :: {:ok, t()} | {:error, map()}
  def reselect(%__MODULE__{} = supervisor) do
    with {:ok, candidates} <- validate_portfolio(supervisor.domain, supervisor.state, supervisor.portfolio),
         {:ok, selected} <- choose(candidates) do
      {:ok, %{supervisor | portfolio: candidates, selected: selected}}
    end
  end

  defp validate_portfolio(domain, initial, portfolio) do
    portfolio
    |> Enum.reduce([], fn candidate, acc ->
      case validate_candidate(domain, initial, candidate) do
        {:ok, admitted} -> [admitted | acc]
        {:error, _} -> acc
      end
    end)
    |> case do
      [] -> {:error, %{reason: :no_admissible_policy, initial: initial}}
      admitted -> {:ok, admitted}
    end
  end

  defp validate_candidate(_domain, _initial, %{authority: authority} = candidate) when authority not in [false, nil],
    do: {:error, %{reason: :authority_bearing_candidate, candidate: candidate[:id]}}

  defp validate_candidate(domain, initial, %{id: id, policy: policy, semantics: semantics} = candidate)
       when semantics in [:strong, :strong_cyclic] do
    case FOND.validate_policy(domain, policy, initial, semantics) do
      {:ok, receipt} -> {:ok, candidate |> Map.put(:validation, receipt) |> Map.put_new(:cost, 0)}
      {:error, error} -> {:error, %{reason: :invalid_candidate, candidate: id, cause: error}}
    end
  end

  defp validate_candidate(_domain, _initial, candidate),
    do: {:error, %{reason: :invalid_candidate_shape, candidate: candidate}}

  defp choose(candidates) do
    candidates
    |> Enum.sort_by(fn c -> {rank(c.semantics), c.cost, inspect(c.id)} end)
    |> case do
      [selected | _] -> {:ok, selected}
      [] -> {:error, %{reason: :no_admissible_policy}}
    end
  end

  defp rank(:strong), do: 0
  defp rank(:strong_cyclic), do: 1

  defp admit_outcome(_domain, %{kind: :goal, state: state}, state), do: :ok
  defp admit_outcome(domain, %{kind: :action_intent, state: state, action: action}, outcome) do
    if outcome in FOND.outcomes(domain, state, action), do: :ok,
      else: {:error, %{reason: :unadmitted_outcome, state: state, action: action, outcome: outcome}}
  end
  defp admit_outcome(_domain, intent, outcome), do: {:error, %{reason: :invalid_observation, intent: intent, outcome: outcome}}
end
