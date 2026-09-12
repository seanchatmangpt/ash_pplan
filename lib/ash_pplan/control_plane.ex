defmodule AshPPlan.ControlPlane do
  @moduledoc """
  Composes Ash, AshStateMachine, AshOban and Reactor capability surfaces.

  The result is descriptive control-plane data. It does not authorize or run an
  action. In DfCM terms, this maximizes visible combinations before selection
  while preserving the existing owner of every effectful capability.

  Extension adapters each resolve their own descriptor exactly once. This module
  joins those admitted facts; it does not reimplement extension semantics or infer
  configured capabilities merely from extension presence.
  """

  alias AshPPlan.Oban, as: ObanProjection
  alias AshPPlan.StateMachine

  @doc "Returns the composed capability closure for one Ash resource."
  @spec describe(module()) :: {:ok, map()} | {:error, map()}
  def describe(resource) when is_atom(resource) do
    if Spark.Dsl.is?(resource, Ash.Resource) do
      actions = action_catalog(resource)
      state_machine = optional_surface(StateMachine.describe_resource(resource))
      oban = optional_surface(ObanProjection.describe_resource(resource))

      {:ok,
       %{
         resource: resource,
         actions: actions,
         state_machine: state_machine,
         oban: oban,
         action_links: action_links(actions, state_machine, oban),
         closure: closure(state_machine, oban),
         authority: authority_map(state_machine, oban),
         gaps: gap_map()
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
    |> Enum.map(&action_descriptor/1)
    |> Enum.sort_by(&{&1.type, &1.name})
  end

  defp action_descriptor(action) do
    %{
      name: action.name,
      type: action.type,
      primary?: Map.get(action, :primary?, false),
      public?: Map.get(action, :public?, false),
      transaction?: Map.get(action, :transaction?, false),
      upsert?: Map.get(action, :upsert?, false),
      require_atomic?: Map.get(action, :require_atomic?, false),
      touches_resources: Map.get(action, :touches_resources, []),
      arguments: Enum.map(Map.get(action, :arguments, []), &argument_descriptor/1)
    }
  end

  defp argument_descriptor(argument) do
    %{
      name: argument.name,
      type: argument.type,
      allow_nil?: Map.get(argument, :allow_nil?, true),
      public?: Map.get(argument, :public?, false)
    }
  end

  defp optional_surface({:ok, value}), do: %{available?: true, value: value}
  defp optional_surface({:error, error}), do: %{available?: false, error: error}

  defp action_links(actions, state_machine, oban) do
    transition_actions = transition_actions(state_machine)
    activation_actions = activation_actions(oban)

    Enum.map(actions, fn action ->
      activations = Map.get(activation_actions, action.name, [])

      Map.merge(action, %{
        state_transition?: action.name in transition_actions,
        activations: Enum.map(activations, &Map.take(&1, [:kind, :name])),
        background_activation?: Enum.any?(activations, &(&1.kind == :trigger)),
        temporal_activation?: Enum.any?(activations, &temporal_activation?/1)
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

  defp transition_actions(_surface), do: []

  defp activation_actions(%{available?: true, value: oban}) do
    Enum.group_by(oban.activations, & &1.action)
  end

  defp activation_actions(_surface), do: %{}

  defp temporal_activation?(%{kind: :scheduled_action}), do: true

  defp temporal_activation?(%{kind: :trigger, activation: activation}) do
    Map.get(activation, :scheduler_cron) not in [nil, false]
  end

  defp closure(state_machine, oban) do
    lifecycle = surface_capabilities(state_machine)
    delivery = surface_capabilities(oban)

    %{
      hierarchical_process_semantics?: true,
      nondeterministic_policy_validation?: true,
      semantic_reactor_execution?: true,
      durable_continuation_contract?: true,
      persistent_resource_lifecycle?: state_machine.available?,
      lifecycle_policy_preflight?: Map.get(lifecycle, :policy_preflight?, false),
      lifecycle_atomic_transition?: Map.get(lifecycle, :atomic_transition?, false),
      lifecycle_possible_next_states?: Map.get(lifecycle, :possible_next_states?, false),
      background_activation?: Map.get(delivery, :conditional_activation?, false),
      temporal_activation?: Map.get(delivery, :temporal_activation?, false),
      retry_delivery?: Map.get(delivery, :retry_delivery?, false),
      snooze_cancel_control?: Map.get(delivery, :job_controls_supported?, false),
      actor_propagation?:
        Map.get(delivery, :actor_persistence?, false) ||
          Map.get(delivery, :default_actor?, false),
      tenant_propagation?:
        Map.get(delivery, :tenant_fanout?, false) ||
          Map.get(delivery, :tenant_from_record?, false),
      shared_job_context?: Map.get(delivery, :shared_context?, false),
      chunk_processing?: Map.get(delivery, :chunk_processing?, false),
      stable_background_identity?:
        Map.get(delivery, :stable_worker_identity?, false) &&
          Map.get(delivery, :stable_scheduler_identity?, false)
    }
  end

  defp surface_capabilities(%{available?: true, value: %{capabilities: capabilities}}),
    do: capabilities

  defp surface_capabilities(_surface), do: %{}

  defp authority_map(state_machine, oban) do
    %{
      domain_state: Ash,
      lifecycle_legality: surface_owner(state_machine, AshStateMachine),
      background_and_temporal_delivery: surface_owner(oban, AshOban),
      queue_runtime: Oban,
      saga_execution: Reactor,
      policy_validation: AshPPlan.FOND,
      semantic_compilation: AshPPlan.Compiler,
      continuation_admission: AshPPlan.Continuation,
      control_plane_observation: __MODULE__
    }
  end

  defp surface_owner(%{available?: true, value: %{owner: owner}}, _fallback), do: owner
  defp surface_owner(_surface, fallback), do: fallback

  defp gap_map do
    %{
      universal_continuation_store?: false,
      planner_actuation?: false,
      duplicated_queue_runtime?: false,
      duplicated_state_machine_runtime?: false
    }
  end
end
