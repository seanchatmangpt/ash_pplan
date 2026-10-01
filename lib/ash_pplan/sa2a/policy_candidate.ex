defmodule AshPPlan.SA2A.PolicyCandidate do
  @moduledoc """
  Owner-side SA2A candidate manufacture over AshPPlan's admitted FOND and
  P-PLAN primitives. No execution or authority is performed here.
  """

  alias AshPPlan.SA2A.{Refusal, SubjectGuard}

  def fond(request, opts \\ []) do
    with {:ok, subject} <- SubjectGuard.fetch(request),
         {:ok, domain} <- fetch(request, :domain, :missing_domain),
         {:ok, initial} <- fetch(request, :initial, :missing_initial),
         {:ok, selected} <-
           AshPPlan.select_policy(domain, initial, Keyword.get(opts, :policy_opts, [])) do
      candidate = %{
        subject: subject,
        formalism: :fond,
        authority: :none,
        standing: :candidate,
        mode: selected.mode,
        policy: selected.policy,
        validation: selected.validation,
        planner_subject: selected.subject,
        attempts: Map.get(selected, :attempts, [])
      }

      SubjectGuard.preserve(subject, candidate)
    else
      {:error, %{code: _} = refusal} -> {:error, refusal}
      {:error, reason} -> {:error, Refusal.new(:planner_refused, reason)}
    end
  end

  def powl(request, _opts \\ []) do
    with {:ok, subject} <- SubjectGuard.fetch(request),
         {:ok, plan_iri} <- fetch_binary(request, :plan_iri, :missing_plan_iri),
         %{} = plan <- AshPPlan.plan(plan_iri) do
      SubjectGuard.preserve(subject, %{
        subject: subject,
        formalism: :powl,
        authority: :none,
        standing: :candidate,
        plan_iri: plan_iri,
        plan: plan
      })
    else
      nil -> {:error, Refusal.new(:plan_not_found, Map.get(request, :plan_iri))}
      {:error, %{code: _} = refusal} -> {:error, refusal}
    end
  end

  defp fetch_binary(map, key, code) do
    with {:ok, value} <- fetch(map, key, code) do
      if is_binary(value), do: {:ok, value}, else: {:error, Refusal.new(code, value)}
    end
  end

  defp fetch(map, key, code) do
    case Map.fetch(map, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, Refusal.new(code)}
    end
  end
end
