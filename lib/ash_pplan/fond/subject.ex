defmodule AshPPlan.FOND.Subject do
  @moduledoc """
  Exact-subject identity for FOND policy courts.

  The subject is the tuple `domain × policy × initial × mode`. Identity is
  deterministic over normalized Erlang terms and carries no authority.
  """

  alias AshPPlan.FOND

  @spec bind(FOND.t(), FOND.policy(), FOND.state(), FOND.mode()) :: map()
  def bind(%FOND{} = domain, policy, initial, mode)
      when is_map(policy) and mode in [:strong, :strong_cyclic] do
    normalized = %{
      states: domain.states |> MapSet.to_list() |> Enum.sort(),
      goals: domain.goals |> MapSet.to_list() |> Enum.sort(),
      transitions: normalize_transitions(domain.transitions),
      policy: policy |> Enum.sort(),
      initial: initial,
      mode: mode
    }

    bytes = :erlang.term_to_binary(normalized, [:deterministic])
    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    %{
      schema: "ash_pplan/fond-subject/v1",
      id: "sha256:" <> digest,
      digest: digest,
      mode: mode,
      initial: initial,
      state_count: MapSet.size(domain.states),
      goal_count: MapSet.size(domain.goals),
      policy_decisions: map_size(policy),
      normalized: normalized
    }
  end

  @spec same?(map(), map()) :: boolean()
  def same?(%{id: id}, %{id: id}), do: true
  def same?(_, _), do: false

  defp normalize_transitions(transitions) do
    transitions
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {state, actions} ->
      {state,
       actions
       |> Enum.sort_by(&elem(&1, 0))
       |> Enum.map(fn {action, outcomes} -> {action, Enum.sort(outcomes)} end)}
    end)
  end
end
