defmodule AshPPlan.FOND.Recovery do
  @moduledoc """
  Typed recovery routing for bounded FOND policy failures.

  The output is a next construction edge, never an actuation instruction.
  """

  @spec route(map() | tuple()) :: map()
  def route({:error, %{reason: reason} = error}), do: route(Map.put(error, :reason, reason))
  def route({:error, {:unsolvable, mode, witness}}),
    do: %{action: :respecify_or_expand_domain, mode: mode, witness: witness}

  def route(%{reason: :not_strong} = error),
    do: %{action: :try_strong_cyclic, preserve_subject: true, evidence: error}

  def route(%{reason: :not_strong_cyclic} = error),
    do: %{action: :resynthesize, preserve_subject: true, evidence: error}

  def route(%{reason: reason} = error)
      when reason in [:missing_policy_action, :unavailable_policy_action],
      do: %{action: :resynthesize, preserve_subject: true, evidence: error}

  def route(%{reason: :unknown_initial_state} = error),
    do: %{action: :refuse_identity, preserve_subject: false, evidence: error}

  def route(%{reason: :invalid_policy_request} = error),
    do: %{action: :refuse_shape, preserve_subject: false, evidence: error}

  def route(other), do: %{action: :refuse_unknown, preserve_subject: false, evidence: other}
end
