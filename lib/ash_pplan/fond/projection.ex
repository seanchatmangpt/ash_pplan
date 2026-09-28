defmodule AshPPlan.FOND.Projection do
  @moduledoc """
  Provider-neutral projection of a FOND subject and its current validator
  disposition. Projection authority is always NONE.
  """

  alias AshPPlan.FOND
  alias AshPPlan.FOND.{Subject, Trace}

  @spec portable(FOND.t(), FOND.policy(), FOND.state(), FOND.mode()) :: map()
  def portable(%FOND{} = domain, policy, initial, mode) do
    subject = Subject.bind(domain, policy, initial, mode)
    validation = FOND.validate_policy(domain, policy, initial, mode)

    %{
      schema: "ash_pplan/fond-projection/v1",
      subject_id: subject.id,
      authority: :NONE,
      initial: initial,
      mode: mode,
      goals: domain.goals |> MapSet.to_list() |> Enum.sort(),
      states: domain.states |> MapSet.to_list() |> Enum.sort(),
      policy: policy |> Enum.sort(),
      edges: Trace.edges(domain, policy),
      validator: normalize(validation)
    }
  end

  defp normalize({:ok, report}), do: %{verdict: :admitted, report: report}
  defp normalize({:error, report}), do: %{verdict: :refused, report: report}
end
