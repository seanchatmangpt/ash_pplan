defmodule AshPPlan.Workflow.Project.Reactor do
  @moduledoc """
  Projects a workflow model onto a Reactor via `AshPPlan.Compiler.compile_spec/2`.

  Task dependency edges become step predecessors, so Reactor alone schedules:
  ordered where a dependency exists, concurrent otherwise. `bindings` maps each
  task id to `%{step: module, options: keyword, provider: atom}`; an unbound
  task is refused rather than defaulted. Grants no authority.
  """

  alias AshPPlan.Compiler
  alias AshPPlan.Workflow.Model

  @spec plan(Model.t()) :: map()
  def plan(%Model{} = model) do
    iri = plan_iri(model)

    %{
      iri: iri,
      label: model.name,
      steps:
        for t <- model.tasks do
          %{
            iri: step_iri(model, t.id),
            predecessors: Enum.map(t.depends_on, &step_iri(model, &1)),
            inputs: [],
            outputs: []
          }
        end
    }
  end

  @spec project(Model.t(), map()) :: {:ok, Reactor.t()} | {:error, term()}
  def project(%Model{} = model, bindings) when is_map(bindings) do
    with :ok <- Model.validate(model),
         :ok <- check_bound(model, bindings) do
      handlers =
        Map.new(model.tasks, fn t ->
          %{step: mod} = b = Map.fetch!(bindings, t.id)
          opts = Map.get(b, :options, [])
          {step_iri(model, t.id), if(opts == [], do: mod, else: {mod, opts})}
        end)

      Compiler.compile_spec(plan(model), handlers)
    end
  end

  def project(other, _), do: {:error, %{reason: :not_a_model, value: other}}

  def plan_iri(%Model{name: name}), do: "urn:ash-pplan:workflow:#{name}"
  def step_iri(%Model{} = m, id), do: "#{plan_iri(m)}#step-#{id}"

  defp check_bound(model, bindings) do
    case for(t <- model.tasks, not match?(%{step: _}, Map.get(bindings, t.id)), do: t.id) do
      [] -> :ok
      missing -> {:error, %{reason: :unbound_tasks, tasks: missing}}
    end
  end
end
