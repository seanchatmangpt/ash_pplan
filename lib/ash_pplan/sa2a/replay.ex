defmodule AshPPlan.SA2A.Replay do
  @moduledoc """
  Binds an SA2A caller subject to AshPPlan's existing deterministic FOND replay
  bundle. The planner replay remains evidence; it is never authority.
  """

  alias AshPPlan.FOND.Replay
  alias AshPPlan.SA2A.{Refusal, SubjectGuard}

  def fond(request, candidate, opts \\ []) do
    with {:ok, subject} <- SubjectGuard.fetch(request),
         {:ok, ^subject} <- candidate_subject(candidate),
         {:ok, domain} <- fetch(request, :domain, :missing_domain),
         {:ok, initial} <- fetch(request, :initial, :missing_initial),
         {:ok, bundle} <- Replay.build(domain, candidate.policy, initial, candidate.mode, opts) do
      bound = Replay.bind_fingerprint(bundle)

      {:ok,
       %{
         subject: subject,
         authority: :none,
         standing: :candidate,
         planner_subject: candidate.planner_subject,
         replay_fingerprint: bound.replay_fingerprint,
         bundle: bound
       }}
    else
      {:error, %{code: _} = refusal} -> {:error, refusal}
      {:error, reason} -> {:error, Refusal.new(:planner_refused, reason)}
    end
  end

  defp candidate_subject(%{subject: subject}) when not is_nil(subject), do: {:ok, subject}
  defp candidate_subject(_), do: {:error, Refusal.new(:missing_subject)}

  defp fetch(map, key, code) do
    case Map.fetch(map, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, Refusal.new(code)}
    end
  end
end
