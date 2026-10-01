defmodule AshPPlan.FOND.Supervision.Portfolio do
  alias AshPPlan.FOND.Supervision.Candidate
  def normalize(candidates) when is_list(candidates), do: candidates |> Enum.map(&normalize_one/1) |> Enum.uniq_by(& &1.id) |> Enum.sort_by(&Candidate.stable_key/1)
  defp normalize_one(%Candidate{}=c), do: c
  defp normalize_one(attrs) when is_map(attrs), do: Candidate.new(attrs)
end
