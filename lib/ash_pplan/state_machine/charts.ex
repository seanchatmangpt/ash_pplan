defmodule AshPPlan.StateMachine.Charts do
  @moduledoc """
  Delegates lifecycle visualization to `AshStateMachine.Charts`.

  Diagram generation is observation only. The upstream extension remains the
  owner of the transition graph and rendering semantics.
  """

  @charts_module Module.concat(["AshStateMachine", "Charts"])

  @doc "Returns the upstream Mermaid state diagram for a configured resource."
  @spec render(module(), :state | :flow) :: {:ok, String.t()} | {:error, map()}
  def render(resource, type \\ :state) when is_atom(resource) and type in [:state, :flow] do
    with {:ok, _lifecycle} <- AshPPlan.StateMachine.describe_resource(resource),
         true <- Code.ensure_loaded?(@charts_module) do
      function =
        case type do
          :state -> :mermaid_state_diagram
          :flow -> :mermaid_flowchart
        end

      {:ok, apply(@charts_module, function, [resource])}
    else
      {:error, error} -> {:error, error}
      false -> {:error, %{reason: :ash_state_machine_charts_not_available, resource: resource}}
    end
  end
end
