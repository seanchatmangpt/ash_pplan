defmodule AshPPlan.Workflow.Authority do
  @moduledoc """
  Authority admission for workflows.

  Planning grants no authority: a valid workflow only declares per-task
  authority ceilings, and the maximum ceiling is `:construct`. Any `:do` (or any
  unknown) authority is refused with a typed error. Admission delegates to
  `AshPPlan.PolicyClosure.AuthorityCeiling`.
  """

  alias AshPPlan.PolicyClosure.AuthorityCeiling
  alias AshPPlan.Workflow.Model

  @order [:observe, :select, :construct]

  @doc """
  Admit a task authority, a list of authorities, a task, or a model.
  Returns `{:ok, ceiling}` (the highest admitted authority) or a typed error.
  """
  @spec admit(atom() | [atom()] | struct()) :: {:ok, atom()} | {:error, map()}
  def admit(%Model{tasks: tasks}) do
    case admit_all(Enum.map(tasks, &{&1.id, &1.authority})) do
      {:ok, []} -> {:ok, :observe}
      {:ok, auths} -> {:ok, highest(auths)}
      error -> error
    end
  end

  def admit(%{authority: authority, id: id}) do
    case admit_all([{id, authority}]) do
      {:ok, [a]} -> {:ok, a}
      error -> error
    end
  end

  def admit(list) when is_list(list) do
    case admit_all(Enum.map(list, &{nil, &1})) do
      {:ok, []} -> {:ok, :observe}
      {:ok, auths} -> {:ok, highest(auths)}
      error -> error
    end
  end

  def admit(authority) when is_atom(authority) do
    case AuthorityCeiling.admit(authority) do
      {:ok, a} -> {:ok, a}
      {:error, _} -> {:error, refusal(nil, authority)}
    end
  end

  def admit(other), do: {:error, refusal(nil, other)}

  @doc "Planning grants nothing: the authority granted by any valid plan."
  @spec granted(Model.t()) :: [atom()]
  def granted(%Model{}), do: []

  defp admit_all(pairs) do
    refused =
      for {id, a} <- pairs, match?({:error, _}, AuthorityCeiling.admit(a)), do: refusal(id, a)

    case refused do
      [] -> {:ok, Enum.map(pairs, &elem(&1, 1))}
      [first | _] -> {:error, Map.put(first, :refused, refused)}
    end
  end

  defp highest(auths), do: Enum.max_by(auths, fn a -> Enum.find_index(@order, &(&1 == a)) end)

  defp refusal(task, authority) do
    %{reason: :authority_ceiling, task: task, authority: authority, max: :construct}
  end
end
