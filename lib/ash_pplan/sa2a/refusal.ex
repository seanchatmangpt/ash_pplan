defmodule AshPPlan.SA2A.Refusal do
  @moduledoc false

  @codes [
    :missing_subject,
    :missing_domain,
    :missing_initial,
    :missing_plan_iri,
    :plan_not_found,
    :unsupported_formalism,
    :planner_refused
  ]

  def new(code, detail \\ nil) when code in @codes,
    do: %{code: code, detail: detail, authority: :none}

  def codes, do: @codes
end
