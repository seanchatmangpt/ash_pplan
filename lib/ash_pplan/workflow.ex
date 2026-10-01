defmodule AshPPlan.Workflow do
  @moduledoc """
  Spark DSL for declaring a semantic workflow.

      defmodule MyFlow do
        use AshPPlan.Workflow

        workflow do
          goal "verified"
          task :observe, capability: "Repository.Observe", outcomes: [:ok]
          task :verify, capability: "Verification.Run", after: [:observe]
        end
      end

      {:ok, model} = AshPPlan.Workflow.model(MyFlow)

  The module gains `__ash_pplan_workflow__/0` returning the normalized
  `AshPPlan.Workflow.Model`. Verifiers reject duplicate ids, unknown or cyclic
  `after` dependencies, unparseable capabilities and authority above `:construct`.
  The DSL declares semantics only and never grants actuation authority.
  """

  alias AshPPlan.Workflow.Model

  use Spark.Dsl,
    default_extensions: [extensions: [AshPPlan.Workflow.Dsl]]

  @doc "Resolve a DSL module (or an existing model) to a validated `Model`."
  @spec model(module() | Model.t()) :: {:ok, Model.t()} | {:error, map()}
  def model(%Model{} = model) do
    with :ok <- validate(model), do: {:ok, model}
  end

  def model(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__ash_pplan_workflow__, 0) do
      model(module.__ash_pplan_workflow__())
    else
      {:error, %{reason: :not_a_workflow, module: module}}
    end
  end

  def model(other), do: {:error, %{reason: :not_a_workflow, module: other}}

  defp validate(%Model{} = model) do
    attrs = %{
      name: model.name,
      version: model.version,
      goal: model.goal,
      tasks: model.tasks,
      methods: model.methods
    }

    with {:ok, _} <- Model.new(attrs), do: :ok
  end
end
