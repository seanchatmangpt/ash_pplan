defmodule AshPPlan.Workflow.Method do
  @moduledoc "An HDDL decomposition method: a compound task refined into ordered subtasks."
  @enforce_keys [:id, :task]
  defstruct id: nil, task: nil, subtasks: [], precondition: nil

  @type t :: %__MODULE__{}
end
