defmodule AshPPlan.Workflow.Dsl.Task do
  @moduledoc "DSL entity struct for `task`. `after` maps to `AshPPlan.Workflow.Task.depends_on`."
  defstruct [
    :id,
    :__identifier__,
    :capability,
    :__spark_metadata__,
    after: [],
    outcomes: [],
    properties: [],
    evidence: [],
    authority: :construct
  ]
end
