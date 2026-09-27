defmodule AshPPlan.FOND.PolicySupervisor do
  @moduledoc """
  Powerless FOND policy portfolio supervisor.

  Selects and revises policies; it never executes domain actions. Planner,
  policy, provider, authority and execution remain separate values.
  """
  alias AshPPlan.FOND

  @enforce_keys [:domain, :state, :providers]
  defstruct [:domain, :state, :providers, :selection, epoch: 0, observations: []]

  @type offer :: %{required(:provider) => term(), required(:policy) => map(),
                   required(:mode) => :strong | :strong_cyclic, optional(:cost) => number(),
                   optional(:authority) => term()}
  @type t :: %__MODULE__{}

  def new(%FOND{}=domain, state, providers) when is_list(providers),
    do: %__MODULE__{domain: domain, state: state, providers: providers}

  def select(%__MODULE__{}=s, offers) when is_list(offers) do
    offers
    |> Enum.reduce([], fn offer, acc ->
      case admit_offer(s, offer) do {:ok, x} -> [x|acc]; _ -> acc end
    end)
    |> Enum.sort_by(fn x -> {mode_rank(x.mode), x.cost, stable(x.provider), stable(x.policy)} end)
    |> case do
      [] -> {:error, %{reason: :no_admissible_policy, state: s.state, epoch: s.epoch}}
      [choice|_] ->
        receipt = receipt(:selected, s, %{provider: choice.provider, mode: choice.mode})
        {:ok, %{s | selection: choice}, receipt}
    end
  end

  def observe(%__MODULE__{selection: nil}, _action, _outcome, _epoch),
    do: {:error, %{reason: :no_selected_policy}}

  def observe(%__MODULE__{epoch: expected}=s, _action, _outcome, epoch) when epoch != expected,
    do: {:error, %{reason: :stale_epoch, expected: expected, observed: epoch}}

  def observe(%__MODULE__{}=s, action, outcome, epoch) do
    expected_action = Map.get(s.selection.policy, s.state)
    outcomes = FOND.outcomes(s.domain, s.state, action)

    cond do
      action != expected_action ->
        {:error, %{reason: :unexpected_action, expected: expected_action, observed: action}}
      outcome not in outcomes ->
        {:error, %{reason: :inadmissible_outcome, action: action, observed: outcome, admitted: outcomes}}
      true ->
        next = %{s | state: outcome, observations: [{s.state, action, outcome}|s.observations]}
        {:ok, next, receipt(:observed, next, %{action: action, outcome: outcome, epoch: epoch})}
    end
  end

  def provider_down(%__MODULE__{}=s, provider) do
    providers = Enum.reject(s.providers, &(&1 == provider))
    selection = if s.selection && s.selection.provider == provider, do: nil, else: s.selection
    %{s | providers: providers, selection: selection, epoch: s.epoch + 1}
  end

  def construct(%__MODULE__{selection: nil}), do: {:error, %{reason: :no_selected_policy}}
  def construct(%__MODULE__{}=s) do
    case Map.fetch(s.selection.policy, s.state) do
      {:ok, action} -> {:ok, %{kind: :fond_action_intent, action: action, state: s.state,
                               provider: s.selection.provider, epoch: s.epoch,
                               authority: :none, do: false}}
      :error -> {:error, %{reason: :policy_terminal_or_incomplete, state: s.state}}
    end
  end

  defp admit_offer(s, %{provider: p, policy: policy, mode: mode}=offer)
       when mode in [:strong, :strong_cyclic] and is_map(policy) do
    cond do
      p not in s.providers -> {:error, :provider_unavailable}
      Map.get(offer, :authority, :none) != :none -> {:error, :authority_bearing_offer}
      true ->
        case FOND.validate_policy(s.domain, policy, s.state, mode) do
          {:ok, _} -> {:ok, %{provider: p, policy: policy, mode: mode, cost: Map.get(offer,:cost,0)}}
          {:error, reason} -> {:error, reason}
        end
    end
  end
  defp admit_offer(_, _), do: {:error, :invalid_offer}
  defp mode_rank(:strong), do: 0
  defp mode_rank(:strong_cyclic), do: 1
  defp stable(term), do: :erlang.term_to_binary(term, [:deterministic])
  defp receipt(kind, s, data), do: %{kind: kind, state: s.state, epoch: s.epoch, data: data,
    digest: Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary({kind,s.state,s.epoch,data},[:deterministic])),case: :lower)}
end
