defmodule AshPPlan.SA2A.Provider do
  @moduledoc """
  Owner-side provider surface consumed by AshA2A.Replan.Port.AshPPlan.

  The adapter constructs planner candidates only. It never executes Reactor,
  resumes continuations, inserts Oban work, or grants authority.

  Exports `supports?/1` and `propose/2`. `propose/2` returns either
  `{:ok, candidate}` with `authority: :none` and `standing: :candidate`, or
  `{:error, %{code: code, detail: detail, authority: :none}}` where `code` is
  one of the closed `AshPPlan.SA2A.Refusal.codes/0`. Consumer-side
  consequence-kernel refusal codes are not owned here.

  `propose/2` is total: hostile requests, unknown formalisms and garbage
  opts always return a refusal with a closed code; they never raise.
  """

  alias AshPPlan.SA2A.{Capability, PolicyCandidate, Refusal}

  def supports?(formalism), do: Capability.supports?(formalism)

  def propose(%{formalism: :fond} = request, opts),
    do: valid_opts(opts, request, &PolicyCandidate.fond/2)

  def propose(%{formalism: :powl} = request, opts),
    do: valid_opts(opts, request, &PolicyCandidate.powl/2)

  def propose(%{formalism: formalism}, _opts),
    do: {:error, Refusal.new(:unsupported_formalism, formalism)}

  def propose(_request, _opts),
    do: {:error, Refusal.new(:unsupported_formalism, nil)}

  defp valid_opts(opts, request, fun) when is_list(opts) do
    if Keyword.keyword?(opts) do
      fun.(request, opts)
    else
      {:error, Refusal.new(:planner_refused, {:invalid_opts, opts})}
    end
  end

  defp valid_opts(opts, _request, _fun),
    do: {:error, Refusal.new(:planner_refused, {:invalid_opts, opts})}
end
