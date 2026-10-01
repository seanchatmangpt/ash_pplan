defmodule AshPPlan.Workflow.Explain do
  @moduledoc """
  Answers the PRD section 37 questions about a workflow or a run: what was
  planned, why each provider was chosen or rejected, what authority exists,
  what evidence is bound, what failed and what remains lawful.

  Pure: it reads a model, a resolution, or a run state and executes nothing.
  """

  alias AshPPlan.Workflow.{Evidence, Subject}

  @doc "Explain a workflow (optionally with a `resolve/2` result)."
  @spec workflow(AshPPlan.Workflow.Model.t(), map()) :: map()
  def workflow(model, resolved \\ %{}) do
    subject = Subject.bind(model)

    %{
      what: %{workflow: model.name, goal: model.goal, subject: subject.id},
      why_this_plan:
        Enum.map(
          model.tasks,
          &{&1.id, "requires #{&1.capability}, after #{inspect(&1.depends_on)}"}
        )
        |> Map.new(),
      providers: providers(resolved),
      rejected: rejected(resolved),
      authority: %{granted: [], ceiling: :construct, do_authority: false},
      evidence: Evidence.profile(model),
      failure: %{observed: nil, sealed: nil, alternatives: alternatives(resolved)}
    }
  end

  @doc "Explain a run state produced by the runtime."
  @spec run(map()) :: map()
  def run(state) do
    resolved = %{resolutions: Map.get(state, :resolutions, %{})}
    base = workflow(state.model, resolved)
    obs = state.observation

    %{
      base
      | failure: %{
          observed: obs.state,
          transition: obs.transition,
          failed_task: obs.failed_task,
          sealed: obs.sealed,
          sealed_registry: Map.get(state.registry, :sealed, %{}),
          alternatives: alternatives(resolved)
        }
    }
    |> Map.put(:run, %{
      id: state[:run_id],
      attempt: state[:attempt],
      generation: state.registry.generation
    })
  end

  defp providers(%{resolutions: res}),
    do: Map.new(res, fn {t, r} -> {t, %{provider: r.provider, reason: r.reason}} end)

  defp providers(%{error: e}), do: %{unresolved: e}
  defp providers(_), do: %{}

  defp rejected(%{resolutions: res}), do: Map.new(res, fn {t, r} -> {t, r.rejected} end)
  defp rejected(_), do: %{}

  defp alternatives(%{resolutions: res}),
    do: Map.new(res, fn {t, r} -> {t, Enum.drop(r.candidates, 1)} end)

  defp alternatives(_), do: %{}
end
