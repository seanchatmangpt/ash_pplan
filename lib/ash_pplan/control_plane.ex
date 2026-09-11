defmodule AshPPlan.ControlPlane do
  @moduledoc """
  Composes the Ash, AshStateMachine, AshOban and Reactor capability surfaces.

  The result is descriptive control-plane data. It does not authorize or run an
  action. In DfCM terms, this maximizes visible combinations before selection
  while preserving the existing owner of every effectful capability.
  """

  alias AshPPlan.Oban, as: ObanProjection
  alias AshPPlan.StateMachine

  @doc "Returns the composed capability closure for one Ash resource."
  @spec describe(module()) :: {:ok, map()} | {:error, map()}
  def describe(resource) when is_atom(resource) do
    if Spark.Dsl.is?(resource, Ash.Resource) do
      actions = action_catalog(resource)
      state_machine = optional_capability(StateMachine.describe_resource(resource))
      oban = optional_capability(ObanProjection.activations(resource))

      {:ok,
       %{
         resource: resource,
         actions: actions,
         state_machine: state_machine,
         oban: oban,
         action_links: action_links(actions, state_machine, oban),
         closure: closure(state_machine, oban),
         authority: authority_map(),
         gaps: %{
           universal_continuation_store?: false,
           planner_actuation?: false,
           duplicated_queue_runtime?: false,
           duplicated_state_machine_runtime?: false
         }
       }}
    else
      {:error, %{reason: :not_an_ash_resource, resource: resource}}
    end
  end

  @doc "Returns Ash actions as planner-visible metadata without invoking them."
  @spec action_catalog(module()) :: [map()]
  def action_catalog(resource) when is_atom(resource) do
    resource
    |> Ash.Resource.Info.actions()
    |> Enum.map(fn action ->
      %{
        name: action.name,
        type: action.type,
        primary?: Map.get(action, :primary?, false),
        public?: Map.get(action, :public?, false),
        transaction?: Map.get(action, :transaction?, false),
        upsert?: Map.get(action, :upsert?, false),
        require_atomic?: Map.get(action, :require_atomic?, false),
        touches_resources: Map.get(action, :touches_resources, []),
        arguments:
          action
          |> Map.get(:arguments, [])
          |> Enum.map(fn argument ->
            %{
              name: argument.name,
              type: argument.type,
              allow_nil?: Map.get(argument, :allow_nil?, true),
              public?: Map.get(argument, :public?, false)
            }
          end)
      }
    end)
    |> Enum.sort_by(&{&1.type, &1.name})
  end

  defp optional_capability({:ok, value}), do: %{available?: true, value: value}
  defp optional_capability({:error, error}), do: %{available?: false, error: error}

  defp action_links(actions, state_machine, oban) do
    transition_actions = transition_actions(state_machine)
    activation_actions = activation_actions(oban)

    Enum.map(actions, fn action ->
      activations = Map.get(activation_actions, action.name, [])

      Map.merge(action, %{
        state_transition?: action.name in transition_actions,
        activations: activations,
        background_activation?: Enum.any?(activations, &(&1.kind == :trigger)),
        temporal_activation?: Enum.any?(activations, &(&1.kind == :scheduled_action))
      })
    end)
  end

  defp transition_actions(%{available?: true, value: lifecycle}) do
    lifecycle.transitions
    |> Enum.flat_map(fn
      %{action: :*} -> lifecycle.wildcard_actions
      %{action: actions} when is_list(actions) -> actions
      %{action: action} -> [action]
    end)
    |> Enum.uniq()
  end

  defp transition_actions(_), do: []

  defp activation_actions(%{available?: true, value: activations}) do
    Enum.group_by(activations, & &1.action, &Map.take(&1, [:kind, :name]))
  end

  defp activation_actions(_), do: %{}

  defp closure(state_machine, oban) do
    activations = if oban.available?, do: oban.value, else: []

    %{
      hierarchical_process_semantics?: true,
      nondeterministic_policy_validation?: true,
      semantic_reactor_execution?: true,
      durable_continuation_contract?: true,
      persistent_resource_lifecycle?: state_machine.available?,
      lifecycle_policy_preflight?: state_machine.available?,
      lifecycle_atomic_transition?: state_machine.available?,
      background_activation?: Enum.any?(activations, &(&1.kind == :trigger)),
      temporal_activation?:
        Enum.any?(activations, fn
          %{kind: :scheduled_action} -> true
          %{kind: :trigger, activation: activation} ->
            not is_nil(Map.get(activation, :scheduler_cron))
        end),
      retry_delivery?: activations != [],
      snooze_cancel_control?: activations != [],
      actor_propagation?: activations != [],
      tenant_propagation?: activations != [],
      chunk_processing?: Enum.any?(activations, &(not is_nil(&1.batching)))
    }
  end

  defp authority_map do
    %{
      domain_state: Ash,
      lifecycle_legality: Module.concat(["AshStateMachine"]),
      background_and_temporal_delivery: AshOban,
      queue_runtime: Oban,
      saga_execution: Reactor,
      policy_validation: AshPPlan.FOND,
      semantic_compilation: AshPPlan.Compiler,
      continuation_admission: AshPPlan.Continuation,
      control_plane_observation: __MODULE__
    }
  end
end
