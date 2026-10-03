defmodule AshPPlan.SA2A.Replay do
  @moduledoc """
  Binds an SA2A caller subject to AshPPlan's existing deterministic FOND replay
  bundle. The planner replay remains evidence; it is never authority.

  The surface is total: hostile requests, malformed candidates and garbage
  opts always return `{:error, refusal}` with a closed
  `AshPPlan.SA2A.Refusal.codes/0` code; they never raise.
  """

  alias AshPPlan.FOND.Replay
  alias AshPPlan.SA2A.{Refusal, SubjectGuard}

  def fond(request, candidate, opts \\ []) do
    with {:ok, subject} <- SubjectGuard.fetch(request),
         :ok <- candidate_subject(candidate, subject),
         :ok <- keyword_opts?(opts),
         {:ok, domain} <- fetch(request, :domain, :missing_domain),
         {:ok, initial} <- fetch(request, :initial, :missing_initial),
         {:ok, bundle} <- build_bundle(domain, candidate, initial, opts) do
      bound = Replay.bind_fingerprint(bundle)

      {:ok,
       %{
         subject: subject,
         authority: :none,
         standing: :candidate,
         planner_subject: Map.get(candidate, :planner_subject),
         replay_fingerprint: bound.replay_fingerprint,
         bundle: bound
       }}
    else
      {:error, %{code: _} = refusal} -> {:error, refusal}
      {:error, reason} -> {:error, Refusal.new(:planner_refused, reason)}
    end
  end

  defp candidate_subject(candidate, subject) when is_map(candidate) do
    case Map.get(candidate, :subject) do
      ^subject -> :ok
      nil -> {:error, Refusal.new(:missing_subject)}
      drifted -> {:error, Refusal.new(:planner_refused, {:subject_drift, subject, drifted})}
    end
  end

  defp candidate_subject(_candidate, _subject), do: {:error, Refusal.new(:missing_subject)}

  defp build_bundle(domain, candidate, initial, opts) do
    policy = Map.get(candidate, :policy)
    mode = Map.get(candidate, :mode)

    cond do
      not is_struct(domain, AshPPlan.FOND) ->
        {:error, {:invalid_domain, domain}}

      not is_map(policy) or mode not in [:strong, :strong_cyclic] ->
        {:error, {:invalid_candidate, [:policy, :mode]}}

      true ->
        Replay.build(domain, policy, initial, mode, opts)
    end
  end

  defp keyword_opts?(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: :ok, else: {:error, {:invalid_opts, opts}}
  end

  defp keyword_opts?(opts), do: {:error, {:invalid_opts, opts}}

  defp fetch(map, key, code) do
    case Map.fetch(map, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, Refusal.new(code)}
    end
  end
end
