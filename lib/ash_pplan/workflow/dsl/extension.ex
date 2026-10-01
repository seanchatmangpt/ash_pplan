defmodule AshPPlan.Workflow.Dsl do
  @moduledoc """
  Spark extension behind `use AshPPlan.Workflow`.

      defmodule MyFlow do
        use AshPPlan.Workflow

        workflow do
          goal "ship"

          task :observe, capability: "Repository.Observe", outcomes: [:ok]
          task :build, capability: "Work.Select", after: [:observe]
        end
      end

  `after` is passed as a keyword option (it is a reserved word and cannot be a
  do-block call). It maps to `AshPPlan.Workflow.Task.depends_on`.

  The DSL describes semantics only. It grants no authority: `authority` is a
  ceiling that must not exceed `:construct`.
  """

  alias AshPPlan.Workflow.Dsl.{Method, Task}

  @task %Spark.Dsl.Entity{
    name: :task,
    describe: "A capability requirement with ordering, outcomes and properties.",
    target: Task,
    args: [:id],
    identifier: :id,
    schema: [
      id: [type: :atom, required: true, doc: "Unique task id."],
      capability: [type: {:or, [:string, :atom]}, required: true, doc: "`Family.Name`."],
      after: [type: {:list, :atom}, default: [], doc: "Task ids this task depends on."],
      outcomes: [type: {:list, :atom}, default: [], doc: "Declared nondeterministic outcomes."],
      properties: [type: {:list, :atom}, default: [], doc: "Execution properties."],
      evidence: [type: {:list, :atom}, default: [], doc: "Required evidence kinds."],
      authority: [type: :atom, default: :construct, doc: "Authority ceiling (max :construct)."]
    ]
  }

  @method %Spark.Dsl.Entity{
    name: :method,
    describe: "An HDDL decomposition of a compound task into ordered subtasks.",
    target: Method,
    args: [:id],
    identifier: :id,
    schema: [
      id: [type: :atom, required: true],
      task: [type: :atom, required: true, doc: "The compound task refined."],
      subtasks: [type: {:list, :atom}, default: [], doc: "Ordered declared task ids."],
      precondition: [type: :any, doc: "Optional applicability condition."]
    ]
  }

  @workflow %Spark.Dsl.Section{
    name: :workflow,
    describe: "Workflow goal, tasks and methods.",
    schema: [
      name: [type: {:or, [:atom, :string]}, doc: "Workflow name (default: module name)."],
      goal: [type: {:or, [:string, :atom]}, doc: "Workflow goal."],
      version: [type: :pos_integer, default: 1]
    ],
    entities: [@task, @method]
  }

  use Spark.Dsl.Extension,
    sections: [@workflow],
    transformers: [AshPPlan.Workflow.Dsl.Transformers.GenerateModel],
    verifiers: [
      AshPPlan.Workflow.Dsl.Verifiers.UniqueIds,
      AshPPlan.Workflow.Dsl.Verifiers.CapabilitiesParse,
      AshPPlan.Workflow.Dsl.Verifiers.AcyclicDependencies,
      AshPPlan.Workflow.Dsl.Verifiers.OutcomeClosure
    ]
end
