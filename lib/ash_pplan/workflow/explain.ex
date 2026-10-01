defmodule AshPPlan.Workflow.Explain do
  @moduledoc """
  Answers the PRD section 37 questions about a workflow or a run: what was
  planned, why each provider was chosen or rejected, what authority exists,
  what evidence is bound, what failed and what remains lawful.

  Pure: it reads a model, a resolution, or a run state and executes nothing.
  """

  alias AshPPlan.Reactor.Durable.{Counterfactual, Engine, Run}
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
    |> put_durable(state)
    |> put_counterfactual(state)
  end

  @doc """
  Counterfactual replay of a durable run state: what would have happened had `change` applied
  (`%{provider: %{task => provider_or_realization}} | %{policy: ..} | %{outputs: ..}`, see
  `AshPPlan.Reactor.Durable.Counterfactual`). Returns the compact summary
  `%{change:, original_outcome:, counterfactual_outcome:, tasks_reexecuted:, diff:}`, or a typed
  refusal. The original run is not touched.
  """
  @spec counterfactual(map(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def counterfactual(state, change, opts \\ [])

  def counterfactual(%{store: store, run_id: run_id}, change, opts) do
    with {:ok, r} <- Counterfactual.replay(store, run_id, [change: change] ++ opts) do
      {:ok,
       %{
         change: change,
         original_outcome: r.original.status,
         counterfactual_outcome: r.counterfactual.status,
         tasks_reexecuted: r.diff.tasks_reexecuted,
         original_untouched: r.untouched?,
         diff: r.diff
       }}
    end
  end

  def counterfactual(_state, _change, _opts), do: {:error, %{reason: :not_a_durable_run}}

  # "What if" section: the lawful alternative providers per task (always), plus the replayed
  # consequence of `state.counterfactual` (a change) for a durable run when one is requested.
  defp put_counterfactual(explained, state) do
    replayed =
      case {Map.get(state, :counterfactual), state} do
        {nil, _} -> nil
        {change, %{store: _, run_id: _}} -> counterfactual(state, change) |> unwrap()
        {change, _} -> %{change: change, refused: :not_a_durable_run}
      end

    Map.put(explained, :counterfactual, %{
      what_if: explained.failure.alternatives,
      replayed: replayed
    })
  end

  defp unwrap({:ok, summary}), do: summary
  defp unwrap({:error, detail}), do: %{refused: detail}

  # Durable runs additionally report the ledger status, what the run waits on and the
  # checkpoint tape (standing checkpoint labels in order). Absent for in-process runs.
  defp put_durable(explained, %{store: store, run_id: run_id}) do
    mod = Run.store_module()

    durable =
      case Engine.fetch(store, run_id) do
        %{status: status} ->
          %{
            run_id: run_id,
            status: status,
            waiting_on: store |> mod.waiters(run_id) |> Enum.map(& &1.name),
            checkpoints: store |> Engine.steps(run_id) |> Enum.map(& &1.label)
          }

        _ ->
          %{run_id: run_id, status: nil, waiting_on: [], checkpoints: []}
      end

    Map.put(explained, :durable, durable)
  end

  defp put_durable(explained, _state), do: explained

  defp providers(%{resolutions: res}),
    do:
      Map.new(res, fn {t, r} ->
        {t,
         %{
           provider: r.provider,
           adapter: Map.get(r, :adapter),
           op: Map.get(r, :op),
           reason: r.reason
         }}
      end)

  defp providers(%{error: e}), do: %{unresolved: e}
  defp providers(_), do: %{}

  defp rejected(%{resolutions: res}), do: Map.new(res, fn {t, r} -> {t, r.rejected} end)
  defp rejected(_), do: %{}

  defp alternatives(%{resolutions: res}),
    do: Map.new(res, fn {t, r} -> {t, Enum.drop(r.candidates, 1)} end)

  defp alternatives(_), do: %{}
end
