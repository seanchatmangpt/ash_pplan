defmodule AshPPlan.PolicyClosure.Provenance do
  def bind(sha, source, by), do: %{source_sha: sha, source: source, derived_by: by}
end
