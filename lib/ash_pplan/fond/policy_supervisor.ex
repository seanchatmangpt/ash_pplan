defmodule AshPPlan.FOND.PolicySupervisor do
  @moduledoc """
  Pure FOND policy supervision.

  The supervisor validates candidate policies, selects a deterministic winner,
  observes nondeterministic outcomes, invalidates stale selections, and falls
  back across planner providers. It owns no executor and carries no DO authority.
  """

  alias AshPPlan.FOND

  @enforce_keys [:domain, :initial, :state, :providers, :candidates, :epoch]
  defstruct [
    :domain,
    :initial,
    :state,
    :selected,
    :receipt,
    :last_observation,
    providers: [],
    candidates: [],
    rejected: [],
    epoch: 0,
    history: []
  ]

  @type provider :: term()
  @type candidate :: %{
          required(:provider) => provider(),
          required(:policy) => FOND.policy(),
          optional(:mode) => FOND.mode(),
          optional(:cost) => non_neg_integer(),
          optional(:id) => term(),
          optional(:authority) => term()
        }
  @type t :: %__MODULE__{}

  @spec new(FOND.t(), FOND.state(), [provider()]) :: {:ok, t()} | {:error, map()}
  def new(%FOND{} = domain, initial, providers) when is_list(providers) do
    providers = providers |> Enum.uniq() |> Enum.sort()

    if MapSet.member?(domain.states, initial) do
      {:ok,
       %__MODULE__{
         domain: domain,
         initial: initial,
         state: initial,
         providers: providers,
         candidates: [],
         epoch: 0
       }}
    else
      {:error, %{reason: :unknown_initial_state, state: initial}}
    end
  end

  def new(_domain, initial, providers),
    do: {:error, %{reason: :invalid_supervisor_request, initial: initial, providers: providers}}

  @doc "Admits a candidate portfolio and deterministically selects the best valid policy."
  @spec select(t(), [candidate()]) :: {:ok, t(), map()} | {:error, map(), t()}
  def select(%__MODULE__{} = supervisor, candidates) when is_list(candidates) do
    {valid, rejected} =
      candidates
      |> Enum.map(&normalize_candidate/1)
      |> Enum.reduce({[], []}, fn
        {:ok, candidate}, {valid, rejected} ->
          case admit_candidate(supervisor, candidate) do
            {:ok, admitted} -> {[admitted | valid], rejected}
            {:error, refusal} -> {valid, [refusal | rejected]}
          end

        {:error, refusal}, {valid, rejected} ->
          {valid, [refusal | rejected]}
      end)

    case Enum.sort_by(valid, &rank/1) do
      [] ->
        next = %{supervisor | candidates: [], rejected: Enum.reverse(rejected), selected: nil}

        {:error,
         %{
           reason: :no_admissible_policy,
           state: supervisor.state,
           epoch: supervisor.epoch,
           rejected: next.rejected
         }, next}

      [selected | _] = ordered ->
        receipt = selection_receipt(supervisor, selected, ordered)
        event = event(:policy_selected, supervisor, %{selection: receipt})

        next = %{
          supervisor
          | candidates: ordered,
            rejected: Enum.reverse(rejected),
            selected: selected,
            receipt: receipt,
            history: [event | supervisor.history]
        }

        {:ok, next, receipt}
    end
  end

  def select(%__MODULE__{} = supervisor, candidates),
    do:
      {:error, %{reason: :invalid_candidate_portfolio, candidates: candidates, epoch: supervisor.epoch},
       supervisor}

  @doc """
  Observes one environment outcome for the currently selected policy.

  Observation never executes the selected action. The caller supplies the
  observed successor after an external executor has acted.
  """
  @spec observe(t(), FOND.state(), FOND.action(), FOND.state()) ::
          {:ok, t(), map()} | {:reselect, t(), map()} | {:error, map(), t()}
  def observe(%__MODULE__{selected: nil} = supervisor, _from, _action, _outcome),
    do: {:error, %{reason: :no_selected_policy, epoch: supervisor.epoch}, supervisor}

  def observe(%__MODULE__{} = supervisor, from, action, outcome) do
    with :ok <- require_current_state(supervisor, from),
         :ok <- require_selected_action(supervisor, from, action),
         :ok <- require_admitted_outcome(supervisor.domain, from, action, outcome) do
      observation =
        observation_receipt(supervisor, from, action, outcome)

      next =
        supervisor
        |> Map.put(:state, outcome)
        |> Map.put(:last_observation, observation)
        |> Map.update!(:history, &[event(:outcome_observed, supervisor, observation) | &1])

      cond do
        MapSet.member?(supervisor.domain.goals, outcome) ->
          {:ok, %{next | selected: nil}, Map.put(observation, :disposition, :goal)}

        selected_policy_covers?(next, outcome) ->
          {:ok, next, Map.put(observation, :disposition, :continue)}

        true ->
          invalidated =
            next
            |> Map.put(:selected, nil)
            |> Map.put(:receipt, nil)
            |> Map.update!(:epoch, &(&1 + 1))

          {:reselect, invalidated, Map.put(observation, :disposition, :reselect)}
      end
    else
      {:error, refusal} -> {:error, Map.put(refusal, :epoch, supervisor.epoch), supervisor}
    end
  end

  @doc "Revalidates the current portfolio after state/domain drift and selects again."
  @spec reselect(t()) :: {:ok, t(), map()} | {:error, map(), t()}
  def reselect(%__MODULE__{} = supervisor) do
    candidates =
      supervisor.candidates
      |> Enum.map(&Map.take(&1, [:provider, :policy, :mode, :cost, :id]))

    select(%{supervisor | selected: nil, receipt: nil}, candidates)
  end

  @doc "Removes an unavailable provider and deterministically falls back."
  @spec provider_lost(t(), provider()) :: {:ok, t(), map()} | {:error, map(), t()}
  def provider_lost(%__MODULE__{} = supervisor, provider) do
    providers = Enum.reject(supervisor.providers, &(&1 == provider))
    candidates = Enum.reject(supervisor.candidates, &(&1.provider == provider))

    next = %{
      supervisor
      | providers: providers,
        candidates: candidates,
        selected: nil,
        receipt: nil,
        epoch: supervisor.epoch + 1,
        history: [event(:provider_lost, supervisor, %{provider: provider}) | supervisor.history]
    }

    select(next, Enum.map(candidates, &Map.take(&1, [:provider, :policy, :mode, :cost, :id])))
  end

  @doc "Returns OCEL-shaped events in causal order."
  @spec ocel_events(t()) :: [map()]
  def ocel_events(%__MODULE__{} = supervisor), do: Enum.reverse(supervisor.history)

  @doc "Returns the selected action as powerless construction data."
  @spec construct_selection(t()) :: {:ok, map()} | {:error, map()}
  def construct_selection(%__MODULE__{selected: nil, epoch: epoch}),
    do: {:error, %{reason: :no_selected_policy, epoch: epoch}}

  def construct_selection(%__MODULE__{} = supervisor) do
    case Map.fetch(supervisor.selected.policy, supervisor.state) do
      {:ok, action} ->
        {:ok,
         %{
           subject: subject(supervisor),
           epoch: supervisor.epoch,
           state: supervisor.state,
           action: action,
           provider: supervisor.selected.provider,
           policy_id: supervisor.selected.id,
           authority: :none,
           do: false,
           receipt_digest: supervisor.receipt.digest
         }}

      :error ->
        {:error,
         %{reason: :selected_policy_missing_current_state, state: supervisor.state, epoch: supervisor.epoch}}
    end
  end

  defp normalize_candidate(candidate) when is_map(candidate) do
    with {:ok, provider} <- Map.fetch(candidate, :provider),
         {:ok, policy} <- Map.fetch(candidate, :policy),
         true <- is_map(policy) do
      authority = Map.get(candidate, :authority, :none)

      if authority in [:none, nil] do
        {:ok,
         %{
           provider: provider,
           policy: policy,
           mode: Map.get(candidate, :mode, :strong_cyclic),
           cost: Map.get(candidate, :cost, 0),
           id: Map.get(candidate, :id, digest(policy))
         }}
      else
        {:error, %{reason: :authority_bearing_candidate, provider: provider, authority: authority}}
      end
    else
      _ -> {:error, %{reason: :invalid_candidate, candidate: candidate}}
    end
  end

  defp normalize_candidate(candidate), do: {:error, %{reason: :invalid_candidate, candidate: candidate}}

  defp admit_candidate(supervisor, candidate) do
    cond do
      candidate.provider not in supervisor.providers ->
        {:error, %{reason: :provider_not_admitted, provider: candidate.provider, id: candidate.id}}

      candidate.mode not in [:strong, :strong_cyclic] ->
        {:error, %{reason: :invalid_policy_mode, mode: candidate.mode, id: candidate.id}}

      not is_integer(candidate.cost) or candidate.cost < 0 ->
        {:error, %{reason: :invalid_policy_cost, cost: candidate.cost, id: candidate.id}}

      true ->
        case FOND.validate_policy(supervisor.domain, candidate.policy, supervisor.state, candidate.mode) do
          {:ok, validation} -> {:ok, Map.put(candidate, :validation, validation)}
          {:error, refusal} -> {:error, %{reason: :policy_refused, id: candidate.id, refusal: refusal}}
        end
    end
  end

  defp rank(candidate) do
    mode_rank = if candidate.mode == :strong, do: 0, else: 1
    {mode_rank, candidate.cost, stable(candidate.id), stable(candidate.provider), digest(candidate.policy)}
  end

  defp selected_policy_covers?(supervisor, state) do
    MapSet.member?(supervisor.domain.goals, state) or Map.has_key?(supervisor.selected.policy, state)
  end

  defp require_current_state(%{state: state}, state), do: :ok
  defp require_current_state(%{state: current}, supplied),
    do: {:error, %{reason: :stale_state, current: current, supplied: supplied}}

  defp require_selected_action(supervisor, state, action) do
    case Map.fetch(supervisor.selected.policy, state) do
      {:ok, ^action} -> :ok
      {:ok, selected} -> {:error, %{reason: :action_not_selected, selected: selected, supplied: action}}
      :error -> {:error, %{reason: :selected_policy_missing_state, state: state}}
    end
  end

  defp require_admitted_outcome(domain, state, action, outcome) do
    if outcome in FOND.outcomes(domain, state, action),
      do: :ok,
      else: {:error, %{reason: :unadmitted_outcome, state: state, action: action, outcome: outcome}}
  end

  defp selection_receipt(supervisor, selected, ordered) do
    base = %{
      kind: :fond_policy_selection,
      subject: subject(supervisor),
      epoch: supervisor.epoch,
      state: supervisor.state,
      provider: selected.provider,
      policy_id: selected.id,
      semantics: selected.mode,
      cost: selected.cost,
      portfolio: Enum.map(ordered, &{&1.provider, &1.id, &1.mode, &1.cost}),
      authority: :none,
      do: false
    }

    Map.put(base, :digest, digest(base))
  end

  defp observation_receipt(supervisor, from, action, outcome) do
    base = %{
      kind: :fond_outcome_observation,
      subject: subject(supervisor),
      epoch: supervisor.epoch,
      from: from,
      action: action,
      outcome: outcome,
      selection_digest: supervisor.receipt.digest,
      authority: :none,
      do: false
    }

    Map.put(base, :digest, digest(base))
  end

  defp event(activity, supervisor, attrs) do
    %{
      "ocel:activity" => Atom.to_string(activity),
      "ocel:object" => subject(supervisor),
      "ocel:epoch" => supervisor.epoch,
      "ocel:attributes" => attrs
    }
  end

  defp subject(supervisor), do: digest({supervisor.initial, supervisor.domain.states, supervisor.domain.goals, supervisor.domain.transitions})

  defp digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp stable(term), do: :erlang.term_to_binary(term, [:deterministic])
end
