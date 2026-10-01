defmodule AshPPlan.Workflow.Subject do
  @moduledoc """
  One content-addressed identity for a workflow plus the explicit correspondence of
  that identity across projections. Correspondence is computed, never inferred
  from coincidental names.
  """

  alias AshPPlan.Workflow.Model

  @schema "ash_pplan/workflow-subject/v1"

  @spec bind(Model.t()) :: map()
  def bind(%Model{} = model) do
    canonical = Model.canonical(model)

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(canonical, [:deterministic]))
      |> Base.encode16(case: :lower)

    %{
      schema: @schema,
      id: "sha256:" <> digest,
      digest: digest,
      workflow: model.name,
      correspondence: Map.new(model.tasks, &{&1.id, correspondence(model.name, &1.id)})
    }
  end

  @spec same?(map(), map()) :: boolean()
  def same?(%{id: id}, %{id: id}), do: true
  def same?(_, _), do: false

  @doc "Projection-specific names for one semantic task id."
  @spec correspondence(String.t(), atom() | String.t()) :: map()
  def correspondence(workflow, task) do
    iri = "urn:ash-pplan:workflow:#{workflow}##{task}"

    %{
      semantic: iri,
      pplan: iri,
      hddl: "t_#{task}",
      fond: to_string(task),
      reactor: to_string(task)
    }
  end
end
