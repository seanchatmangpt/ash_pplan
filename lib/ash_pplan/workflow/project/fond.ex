defmodule AshPPlan.Workflow.Project.FOND do
  @moduledoc """
  Projects a workflow model's task outcome topology into a FOND domain.

  A FOND state is the sorted list of completed task ids. The action
  `{:run, task}` is admitted once every dependency of `task` is complete. Each
  task outcome is one nondeterministic branch: the first success-like outcome
  (`"success"`, else the first declared outcome) completes the task, every other
  declared outcome is a retry branch that leaves the state unchanged. Goal is
  the state where all tasks are complete.

  A policy is synthesized with `AshPPlan.synthesize_policy/3` when the domain is
  solvable. `unsupported` lists every `{task, outcome}` that no declared
  evidence can observe, so no outcome is silently assumed observable.

  Render only: no authority is granted (ceiling `:construct`).
  """

  alias AshPPlan.Workflow.Model

  @type result :: %{
          domain: AshPPlan.FOND.t(),
          initial: [term()],
          policy: map() | nil,
          mode: :strong | :strong_cyclic,
          refusal: term() | nil,
          observable: [{term(), term()}],
          unsupported: [{term(), term()}]
        }

  @spec project(Model.t(), keyword()) :: {:ok, result()} | {:error, map()}
  def project(model, opts \\ [])

  def project(%Model{} = model, opts) do
    mode = Keyword.get(opts, :mode, :strong_cyclic)

    with :ok <- Model.validate(model),
         {:ok, order} <- Model.topological_order(model),
         {:ok, domain} <- AshPPlan.fond_domain(transitions(model, order), [Enum.sort(order)]) do
      initial = []

      {policy, refusal} =
        case AshPPlan.synthesize_policy(domain, initial, mode) do
          {:ok, policy} -> {policy, nil}
          {:error, reason} -> {nil, reason}
        end

      {observable, unsupported} = split_outcomes(model)

      {:ok,
       %{
         domain: domain,
         initial: initial,
         policy: policy,
         mode: mode,
         refusal: refusal,
         observable: observable,
         unsupported: unsupported
       }}
    end
  end

  def project(other, _opts), do: {:error, %{reason: :not_a_model, value: other}}

  @doc "Outcomes of every task, split into observable (task declares evidence) and unsupported."
  @spec split_outcomes(Model.t()) :: {[{term(), term()}], [{term(), term()}]}
  def split_outcomes(%Model{tasks: tasks}) do
    pairs = for t <- tasks, o <- t.outcomes, do: {t, o}
    {obs, unsup} = Enum.split_with(pairs, fn {t, _o} -> t.evidence != [] end)
    {Enum.map(obs, fn {t, o} -> {t.id, o} end), Enum.map(unsup, fn {t, o} -> {t.id, o} end)}
  end

  defp transitions(%Model{tasks: tasks}, order) do
    all = Enum.sort(order)

    all
    |> subsets()
    |> Map.new(fn done ->
      actions =
        for t <- tasks,
            t.id not in done,
            Enum.all?(t.depends_on, &(&1 in done)),
            into: %{} do
          {{:run, t.id}, branches(t, done)}
        end

      {done, actions}
    end)
  end

  defp branches(task, done) do
    next = Enum.sort([task.id | done])

    case task.outcomes do
      [] -> [next]
      [_] -> [next]
      outcomes -> if success_like(outcomes), do: [next, done], else: [next]
    end
  end

  defp success_like(outcomes), do: length(outcomes) > 1

  defp subsets([]), do: [[]]

  defp subsets([h | t]) do
    rest = subsets(t)
    rest ++ Enum.map(rest, &Enum.sort([h | &1]))
  end
end
