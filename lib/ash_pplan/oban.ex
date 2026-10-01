defmodule AshPPlan.Oban do
  @moduledoc """
  Projects `AshOban` triggers and scheduled actions into planner-visible data.

  AshOban and Oban retain all scheduling and delivery authority. This module
  does not create workers, run schedulers, insert jobs, implement retries, or
  reproduce queue semantics. It reads the resolved public AshOban DSL through
  `AshOban.Info`, derives resource-specific capabilities from that configuration,
  and exposes a CONSTRUCT-only job boundary through `AshOban.build_trigger/3`.
  """

  @outcome_states [:succeeded, :snoozed, :cancelled, :failed, :unknown]
  @job_controls [:retry, :snooze, :cancel]
  @period_units [
    :second,
    :seconds,
    :minute,
    :minutes,
    :hour,
    :hours,
    :day,
    :days,
    :week,
    :weeks
  ]

  @doc "Returns the resolved AshOban surface for one Ash resource."
  @spec describe_resource(module()) :: {:ok, map()} | {:error, map()}
  def describe_resource(resource) when is_atom(resource) do
    with :ok <- ensure_ash_resource(resource),
         :ok <- ensure_configured(resource) do
      activations =
        resource
        |> AshOban.Info.oban_triggers_and_scheduled_actions()
        |> Enum.map(&(resource |> describe(&1) |> resolve_runtime_authority(resource)))
        |> Enum.sort_by(&{&1.kind, &1.name})

      {:ok,
       %{
         owner: AshOban,
         resource: resource,
         activations: activations,
         capabilities: capability_descriptor(activations),
         authority: authority_descriptor()
       }}
    end
  end

  @doc "Returns every AshOban trigger and scheduled action configured on a resource."
  @spec activations(module()) :: {:ok, [map()]} | {:error, map()}
  def activations(resource) when is_atom(resource) do
    with {:ok, descriptor} <- describe_resource(resource) do
      {:ok, descriptor.activations}
    end
  end

  @doc """
  Returns resource-specific AshOban capability facts.

  Activation capabilities (`conditional_activation?`, `temporal_activation?`,
  `retry_delivery?`, actor/tenant/context propagation, chunking, ...) are
  derived only from activations whose `state` is `:active`; AshOban cancels
  every job of a paused or deleted activation. Actor persistence and tenant
  fan-out are read through the same fallbacks AshOban uses at runtime
  (`config :ash_oban, :actor_persister` and the `oban` section's
  `list_tenants`). Identity facts are never claimed over an empty set.
  """
  @spec capabilities(module()) :: {:ok, map()} | {:error, map()}
  def capabilities(resource) when is_atom(resource) do
    with {:ok, descriptor} <- describe_resource(resource) do
      {:ok, descriptor.capabilities}
    end
  end

  @doc "Looks up one configured activation by name."
  @spec fetch_activation(module(), atom()) :: {:ok, map()} | {:error, map()}
  def fetch_activation(resource, name) when is_atom(resource) and is_atom(name) do
    with {:ok, descriptor} <- describe_resource(resource) do
      case Enum.find(descriptor.activations, &(&1.name == name)) do
        nil -> {:error, %{reason: :unknown_ash_oban_activation, resource: resource, name: name}}
        activation -> {:ok, activation}
      end
    end
  end

  @doc """
  Describes one already-resolved AshOban trigger or scheduled action.

  `configuration` preserves every public struct field except Spark bookkeeping,
  while grouped views expose eligibility, activation, delivery, authority,
  inputs, failure handling and batching. Functions remain runtime terms; this
  descriptor is control-plane data, not a serialized receipt.
  """
  @spec describe(module(), AshOban.Trigger.t() | AshOban.Schedule.t()) :: map()
  def describe(resource, %AshOban.Trigger{} = trigger) do
    configuration = public_configuration(trigger)

    %{
      kind: :trigger,
      owner: AshOban,
      resource: resource,
      name: trigger.name,
      action: trigger.action,
      active?: active_state?(trigger.state),
      configuration: configuration,
      eligibility:
        Map.take(configuration, [
          :where,
          :sort,
          :read_action,
          :worker_read_action,
          :record_limit,
          :stream_batch_size,
          :stream_with,
          :lock_for_update?
        ]),
      activation:
        Map.take(configuration, [
          :scheduler_cron,
          :scheduler_queue,
          :scheduler_priority,
          :scheduler_module_name,
          :scheduler,
          :max_scheduler_attempts,
          :state
        ]),
      delivery:
        Map.take(configuration, [
          :queue,
          :worker_priority,
          :worker_module_name,
          :worker,
          :max_attempts,
          :trigger_once?,
          :backoff,
          :timeout,
          :tags,
          :worker_opts
        ]),
      authority:
        Map.take(configuration, [
          :list_tenants,
          :actor_persister,
          :default_actor,
          :shared_context,
          :use_tenant_from_record?
        ]),
      input:
        Map.take(configuration, [
          :action_input,
          :read_metadata,
          :extra_args
        ]),
      failure:
        configuration
        |> Map.take([:on_error, :on_error_fails_job?, :log_errors?, :log_final_error?])
        |> Map.put(:job_controls, @job_controls ++ [:trigger_no_longer_applies]),
      batching: chunk_descriptor(trigger.chunks),
      planner_outcomes: @outcome_states
    }
  end

  def describe(resource, %AshOban.Schedule{} = schedule) do
    configuration = public_configuration(schedule)

    %{
      kind: :scheduled_action,
      owner: AshOban,
      resource: resource,
      name: schedule.name,
      action: schedule.action,
      active?: active_state?(schedule.state),
      configuration: configuration,
      eligibility: %{kind: :cron},
      activation: Map.take(configuration, [:cron, :state]),
      delivery:
        Map.take(configuration, [
          :queue,
          :priority,
          :worker_module_name,
          :worker,
          :max_attempts,
          :tags
        ]),
      authority:
        Map.take(configuration, [
          :list_tenants,
          :actor_persister,
          :default_actor,
          :shared_context
        ]),
      input: Map.take(configuration, [:action_input]),
      failure: %{job_controls: @job_controls, last_attempt_argument?: true},
      batching: nil,
      planner_outcomes: @outcome_states
    }
  end

  @doc """
  Constructs an Oban worker changeset for a record trigger without inserting it.

  This is a CONSTRUCT boundary only. The returned changeset has no delivery
  standing until AshOban/Oban inserts it through an authorized application path.
  """
  @spec construct_trigger(struct(), atom() | AshOban.Trigger.t(), keyword()) ::
          {:ok, term()} | {:error, map()}
  def construct_trigger(record, trigger, opts \\ [])

  def construct_trigger(%resource{} = record, trigger, opts) when is_list(opts) do
    with :ok <- ensure_ash_resource(resource),
         :ok <- ensure_configured(resource),
         {:ok, resolved} <- resolve_trigger(resource, trigger) do
      {:ok, AshOban.build_trigger(record, resolved, opts)}
    end
  end

  def construct_trigger(record, trigger, opts),
    do:
      {:error,
       %{reason: :invalid_ash_oban_construction, record: record, trigger: trigger, options: opts}}

  @doc "Classifies an AshOban/Oban public return or error as a bounded planner observation."
  @spec observation(term()) :: map()
  def observation(:ok), do: %{state: :succeeded, terminal?: true}
  def observation({:ok, value}), do: %{state: :succeeded, terminal?: true, value: value}

  def observation({:snooze, seconds}) when is_integer(seconds) and seconds >= 0 do
    %{state: :snoozed, terminal?: false, retryable?: true, snooze_for: seconds}
  end

  def observation({:snooze, {amount, unit} = period})
      when is_integer(amount) and amount >= 0 and unit in @period_units do
    %{state: :snoozed, terminal?: false, retryable?: true, snooze_for: period}
  end

  def observation({:cancel, reason}) do
    %{state: :cancelled, terminal?: true, retryable?: false, reason: reason}
  end

  # `:discard` and `{:discard, reason}` are deprecated Oban aliases of cancel.
  def observation(:discard) do
    %{
      state: :cancelled,
      terminal?: true,
      retryable?: false,
      reason: :discard,
      deprecated: :discard
    }
  end

  def observation({:discard, reason}) do
    %{state: :cancelled, terminal?: true, retryable?: false, reason: reason, deprecated: :discard}
  end

  def observation({:error, error}) do
    case AshOban.check_for_oban_return(error) do
      {:snooze, seconds} -> observation({:snooze, seconds})
      {:cancel, reason} -> observation({:cancel, reason})
      nil -> %{state: :failed, terminal?: false, retryable?: true, error: error}
    end
  end

  def observation(error) do
    case AshOban.check_for_oban_return(error) do
      {:snooze, seconds} -> observation({:snooze, seconds})
      {:cancel, reason} -> observation({:cancel, reason})
      nil -> %{state: :unknown, terminal?: false, value: error}
    end
  end

  defp ensure_ash_resource(resource) do
    if Spark.Dsl.is?(resource, Ash.Resource) do
      :ok
    else
      {:error, %{reason: :not_an_ash_resource, resource: resource}}
    end
  end

  defp ensure_configured(resource) do
    if AshOban in Spark.extensions(resource) do
      :ok
    else
      {:error, %{reason: :ash_oban_not_configured, resource: resource, extension: AshOban}}
    end
  end

  defp resolve_trigger(resource, %AshOban.Trigger{} = trigger) do
    if trigger in AshOban.Info.oban_triggers(resource) do
      {:ok, trigger}
    else
      {:error, %{reason: :foreign_ash_oban_trigger, resource: resource, trigger: trigger.name}}
    end
  end

  defp resolve_trigger(resource, name) when is_atom(name) do
    case AshOban.Info.oban_trigger(resource, name) do
      nil -> {:error, %{reason: :unknown_ash_oban_trigger, resource: resource, trigger: name}}
      trigger -> {:ok, trigger}
    end
  end

  defp resolve_trigger(resource, trigger),
    do: {:error, %{reason: :unknown_ash_oban_trigger, resource: resource, trigger: trigger}}

  # AshOban resolves these two authority inputs only at job runtime, so the raw
  # DSL value is not the effective configuration. Mirror the upstream fallback.
  defp resolve_runtime_authority(activation, resource) do
    authority = activation.authority

    resolved = %{
      resolved_actor_persister:
        Map.get(authority, :actor_persister) ||
          Application.get_env(:ash_oban, :actor_persister),
      resolved_list_tenants:
        Map.get(authority, :list_tenants) || AshOban.Info.oban_list_tenants!(resource)
    }

    %{activation | authority: Map.merge(authority, resolved)}
  end

  defp capability_descriptor(all_activations) do
    activations = Enum.filter(all_activations, &active?/1)
    triggers = Enum.filter(activations, &(&1.kind == :trigger))
    schedules = Enum.filter(activations, &(&1.kind == :scheduled_action))
    all_triggers = Enum.filter(all_activations, &(&1.kind == :trigger))
    pro? = AshOban.Info.pro?()

    %{
      conditional_activation?: triggers != [],
      temporal_activation?: schedules != [] || Enum.any?(triggers, &temporal_trigger?/1),
      retry_delivery?: Enum.any?(activations, &retry_configured?/1),
      job_controls_supported?: activations != [],
      actor_persistence?: Enum.any?(activations, &actor_persistence_configured?/1),
      default_actor?: Enum.any?(activations, &default_actor_configured?/1),
      tenant_fanout?: Enum.any?(activations, &tenant_fanout_configured?/1),
      tenant_from_record?: Enum.any?(triggers, &tenant_from_record_configured?/1),
      shared_context?: Enum.any?(activations, &shared_context_configured?/1),
      chunk_processing?: Enum.any?(triggers, &(not is_nil(&1.batching))),
      chunk_processing_available?: pro?,
      trigger_once?: Enum.any?(triggers, &Map.get(&1.delivery, :trigger_once?, false)),
      on_error_actions?: Enum.any?(triggers, &(not is_nil(Map.get(&1.failure, :on_error)))),
      stable_worker_identity?:
        all_activations != [] && Enum.all?(all_activations, &worker_identity_stable?/1),
      stable_scheduler_identity?:
        all_triggers != [] && Enum.all?(all_triggers, &scheduler_identity_stable?/1),
      paused_or_deleted_activation?: Enum.any?(all_activations, &(not active?(&1))),
      pro?: pro?,
      job_controls: @job_controls,
      planner_outcomes: @outcome_states
    }
  end

  defp active?(%{active?: active?}), do: active?

  # AshOban defaults `state` to `:active`; generated workers and schedulers
  # cancel every job of a `:paused` or `:deleted` activation.
  defp active_state?(state), do: state in [nil, :active]

  defp authority_descriptor do
    %{
      inspect: AshOban.Info,
      construct: AshOban,
      schedule_and_run: AshOban,
      queue_runtime: Oban,
      domain_state: Ash
    }
  end

  defp temporal_trigger?(%{activation: activation}) do
    Map.get(activation, :scheduler_cron) not in [nil, false]
  end

  defp retry_configured?(%{delivery: delivery} = activation) do
    worker_attempts = Map.get(delivery, :max_attempts, 1)

    scheduler_attempts =
      activation |> Map.get(:activation, %{}) |> Map.get(:max_scheduler_attempts, 1)

    worker_attempts > 1 || scheduler_attempts > 1
  end

  defp actor_persistence_configured?(%{authority: authority}) do
    persister =
      Map.get_lazy(authority, :resolved_actor_persister, fn ->
        Map.get(authority, :actor_persister) ||
          Application.get_env(:ash_oban, :actor_persister)
      end)

    persister not in [nil, :none]
  end

  defp default_actor_configured?(activation) do
    not is_nil(Map.get(activation.authority, :default_actor))
  end

  # `[nil]` is AshOban's "no tenant" default, so it is not a tenant fan-out.
  defp tenant_fanout_configured?(%{authority: authority}) do
    authority
    |> Map.get_lazy(:resolved_list_tenants, fn -> Map.get(authority, :list_tenants) end)
    |> case do
      nil -> false
      [] -> false
      [nil] -> false
      _tenants_or_function -> true
    end
  end

  defp tenant_from_record_configured?(activation) do
    Map.get(activation.authority, :use_tenant_from_record?, false)
  end

  defp shared_context_configured?(activation) do
    Map.get(activation.authority, :shared_context) not in [nil, false, []]
  end

  defp worker_identity_stable?(activation) do
    not is_nil(Map.get(activation.delivery, :worker_module_name))
  end

  defp scheduler_identity_stable?(%{activation: activation}) do
    Map.get(activation, :scheduler_cron) == false ||
      not is_nil(Map.get(activation, :scheduler_module_name))
  end

  defp public_configuration(struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__identifier__, :__spark_metadata__])
  end

  defp chunk_descriptor(nil), do: nil

  defp chunk_descriptor(%AshOban.Chunks{} = chunks) do
    chunks
    |> Map.from_struct()
    |> Map.drop([:__spark_metadata__])
    |> Map.put(:owner, Module.concat(["Oban", "Pro", "Workers", "Chunk"]))
    |> Map.put(:automatic_partitions, [:actor, :tenant_when_multitenant])
    |> Map.put(:bulk_execution, [:update, :destroy])
  end
end
