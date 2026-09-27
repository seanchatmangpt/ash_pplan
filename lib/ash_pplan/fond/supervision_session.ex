defmodule AshPPlan.FOND.SupervisionSession do
  @moduledoc """
  Immutable coordination state for a selected FOND policy and provider.

  The session carries generation and epoch fences so observations from an older
  selection cannot be applied to a newer one.
  """
  @enforce_keys [:provider_id, :semantics, :policy, :state, :provider_generation, :epoch]
  defstruct [:provider_id, :semantics, :policy, :state, :provider_generation, :epoch, history: []]

  def new(selection, policy, state) when is_map(selection) and is_map(policy) do
    with provider_id when not is_nil(provider_id) <- Map.get(selection, :provider_id),
         semantics when semantics in [:strong, :strong_cyclic] <- Map.get(selection, :semantics),
         generation when is_integer(generation) and generation >= 0 <- Map.get(selection, :generation) do
      {:ok, %__MODULE__{provider_id: provider_id, semantics: semantics, policy: policy,
        state: state, provider_generation: generation, epoch: 0,
        history: [%{kind: :opened, state: state, provider_id: provider_id}]}}
    else
      _ -> {:error, %{reason: :invalid_selection, selection: selection}}
    end
  end

  def action(%__MODULE__{} = session) do
    case Map.fetch(session.policy, session.state) do
      {:ok, action} ->
        {:ok, %{state: session.state, action: action, epoch: session.epoch,
                provider_id: session.provider_id, semantics: session.semantics}}
      :error ->
        {:error, %{reason: :no_policy_action, state: session.state, epoch: session.epoch}}
    end
  end

  def advance(%__MODULE__{} = session, next_state, epoch) do
    if epoch == session.epoch do
      {:ok, %{session | state: next_state, epoch: epoch + 1,
        history: session.history ++ [%{kind: :observed, from: session.state,
                                      to: next_state, epoch: epoch + 1}]}}
    else
      {:error, %{reason: :stale_session_epoch, observed: epoch, current: session.epoch}}
    end
  end

  def reseat(%__MODULE__{} = session, selection, policy) when is_map(selection) and is_map(policy) do
    with provider_id when not is_nil(provider_id) <- Map.get(selection, :provider_id),
         semantics when semantics in [:strong, :strong_cyclic] <- Map.get(selection, :semantics),
         generation when is_integer(generation) and generation >= session.provider_generation <-
           Map.get(selection, :generation) do
      {:ok, %{session | provider_id: provider_id, semantics: semantics, policy: policy,
        provider_generation: generation, epoch: session.epoch + 1,
        history: session.history ++ [%{kind: :reseated, provider_id: provider_id,
                                      semantics: semantics, generation: generation,
                                      epoch: session.epoch + 1}]}}
    else
      _ -> {:error, %{reason: :invalid_reselection, selection: selection}}
    end
  end
end
