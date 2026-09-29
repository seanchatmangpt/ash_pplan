defmodule AshPPlan.SA2A.SubjectGuard do
  @moduledoc """
  Exact caller-subject preservation for owner-side SA2A planner candidates.
  """

  alias AshPPlan.SA2A.Refusal

  def fetch(%{subject: subject}) when not is_nil(subject), do: {:ok, subject}
  def fetch(_), do: {:error, Refusal.new(:missing_subject)}

  def preserve(subject, %{subject: subject} = candidate), do: {:ok, candidate}

  def preserve(subject, candidate) when is_map(candidate),
    do: {:error, %{code: :planner_refused, detail: {:subject_drift, subject, Map.get(candidate, :subject)}, authority: :none}}
end
