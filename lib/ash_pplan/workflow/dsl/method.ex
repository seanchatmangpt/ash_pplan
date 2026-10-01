defmodule AshPPlan.Workflow.Dsl.Method do
  @moduledoc "DSL entity struct for `method` (an HDDL decomposition of a compound task)."
  defstruct [:id, :__identifier__, :task, :precondition, :__spark_metadata__, subtasks: []]
end
