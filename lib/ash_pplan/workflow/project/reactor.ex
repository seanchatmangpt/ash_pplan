defmodule AshPPlan.Workflow.Project.Reactor do
  @moduledoc """
  Projects a workflow model onto a Reactor via `AshPPlan.Compiler.compile_spec/2`.

  Task dependency edges become step predecessors, so Reactor alone schedules:
  ordered where a dependency exists, concurrent otherwise. `bindings` maps each
  task id to an `AshPPlan.Realization`, bound to a step by `AshPPlan.Reactor.step_for/1`; an unbound
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

  @spec project(Model.t(), map(), keyword()) :: {:ok, Reactor.t()} | {:error, term()}
  def project(model, bindings, opts \\ [])

  def project(%Model{} = model, bindings, opts) when is_map(bindings) do
    with :ok <- Model.validate(model),
         :ok <- check_bound(model, bindings),
         {:ok, handlers} <- handlers(model, bindings, opts) do
      Compiler.compile_spec(plan(model), handlers)
    end
  end

  def project(other, _, _), do: {:error, %{reason: :not_a_model, value: other}}

  def plan_iri(%Model{name: name}), do: "urn:ash-pplan:workflow:#{name}"

  def step_iri(%Model{name: name}, id),
    do: AshPPlan.Workflow.Subject.correspondence(name, id).reactor

  # Realizations become steps ONLY through `AshPPlan.Reactor.step_for/1`.
  defp handlers(model, bindings, opts) do
    Enum.reduce_while(model.tasks, {:ok, %{}}, fn t, {:ok, acc} ->
      case AshPPlan.Reactor.step_for(Map.fetch!(bindings, t.id), Keyword.take(opts, [:adapters])) do
        {:ok, {mod, opts}} ->
          {:cont,
           {:ok, Map.put(acc, step_iri(model, t.id), if(opts == [], do: mod, else: {mod, opts}))}}

        {:error, detail} ->
          {:halt, {:error, %{reason: :unsupported_realization, task: t.id, detail: detail}}}
      end
    end)
  end

  defp check_bound(model, bindings) do
    case for(
           t <- model.tasks,
           not match?(%AshPPlan.Realization{}, Map.get(bindings, t.id)),
           do: t.id
         ) do
      [] -> :ok
      missing -> {:error, %{reason: :unbound_tasks, tasks: missing}}
    end
  end
end
