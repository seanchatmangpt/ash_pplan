defmodule AshPPlan.Workflow.Project.PPlan do
  @moduledoc """
  Projects a `AshPPlan.Workflow.Model` to the pure-data plan map consumed by
  `AshPPlan.Compiler.compile_spec/2`. Step IRIs come from
  `AshPPlan.Workflow.Subject.correspondence/2`; steps are emitted in
  dependency-respecting order. The projection grants no authority.
  """

  alias AshPPlan.Workflow.{Model, Subject}

  @spec plan_iri(Model.t()) :: String.t()
  def plan_iri(%Model{name: name}), do: "urn:ash-pplan:workflow:#{name}"

  @spec step_iri(Model.t(), atom() | String.t()) :: String.t()
  def step_iri(%Model{name: name}, task), do: Subject.correspondence(name, task).pplan

  @spec project(Model.t()) :: %{iri: String.t(), label: String.t(), steps: [map()]}
  def project(%Model{} = model) do
    {:ok, order} = Model.topological_order(model)
    by_id = Map.new(model.tasks, &{&1.id, &1})

    steps =
      Enum.map(order, fn id ->
        task = Map.fetch!(by_id, id)
        iri = step_iri(model, id)
        preds = Enum.map(task.depends_on, &step_iri(model, &1))

        %{
          iri: iri,
          predecessors: preds,
          inputs: Enum.map(preds, &(&1 <> "/output")),
          outputs: [iri <> "/output"]
        }
      end)

    %{iri: plan_iri(model), label: to_string(model.name), steps: steps}
  end
end
