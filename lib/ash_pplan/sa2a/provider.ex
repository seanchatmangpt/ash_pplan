defmodule AshPPlan.SA2A.Provider do
  @moduledoc """
  Owner-side provider surface consumed by AshA2A.Replan.Port.AshPPlan.

  The adapter constructs planner candidates only. It never executes Reactor,
  resumes continuations, inserts Oban work, or grants authority.
  """

  alias AshPPlan.SA2A.{Capability, PolicyCandidate, Refusal}

  def supports?(formalism), do: Capability.supports?(formalism)

  def propose(%{formalism: :fond} = request, opts),
    do: PolicyCandidate.fond(request, opts)

  def propose(%{formalism: :powl} = request, opts),
    do: PolicyCandidate.powl(request, opts)

  def propose(%{formalism: formalism}, _opts),
    do: {:error, Refusal.new(:unsupported_formalism, formalism)}

  def propose(_request, _opts),
    do: {:error, Refusal.new(:unsupported_formalism, nil)}
end
