defmodule AshPPlan.StateMachine.Charts do
  @moduledoc """
  Delegates lifecycle visualization to `AshStateMachine.Charts`.

  Diagram generation is observation only. The upstream extension remains the
  owner of the transition graph and rendering semantics.
  """

  @type diagram_type :: :state | :flow

  @doc "Returns the upstream Mermaid diagram for a configured resource."
  @spec render(module(), diagram_type()) :: {:ok, String.t()} | {:error, map()}
  def render(resource, type \\ :state) when is_atom(resource) and type in [:state, :flow] do
    with {:ok, _lifecycle} <- AshPPlan.StateMachine.describe_resource(resource) do
      {:ok, render_upstream(resource, type)}
    end
  end

  defp render_upstream(resource, :state),
    do: AshStateMachine.Charts.mermaid_state_diagram(resource)

  defp render_upstream(resource, :flow),
    do: AshStateMachine.Charts.mermaid_flowchart(resource)
end
