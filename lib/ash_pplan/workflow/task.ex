defmodule AshPPlan.Workflow.Task do
  @moduledoc "A workflow task: a capability requirement with ordering, outcomes and properties."
  @enforce_keys [:id]
  defstruct id: nil,
            capability: nil,
            depends_on: [],
            outcomes: [],
            properties: [],
            evidence: [],
            authority: :construct

  @type t :: %__MODULE__{}
end
