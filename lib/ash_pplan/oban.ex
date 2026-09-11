defmodule AshPPlan.Oban do
  @moduledoc """
  Projects `AshOban` triggers and scheduled actions into planner-visible data.

  AshOban and Oban retain all scheduling and delivery authority. This module
  does not create workers, run schedulers, insert jobs, implement retries, or
  reproduce queue semantics. Instead it exposes the already-resolved AshOban
  configuration as a stable control-plane description and classifies public job
  outcomes for downstream planning.

  This preserves the AshOban design principle that application/resource state
  is authoritative and background jobs are delivery mechanisms rather than a
  second domain model.
  """

  @outcome_states [:succeeded, :snoozed, :cancelled, :failed, :unknown]

  @doc "Returns every AshOban trigger and scheduled action configured on a resource."
  @spec activations(module()) :: {:ok, [map()]} | {:error, map()}
  def activations(resource) when is_atom(resource) do
    if resource_uses_extension?(resource) do
      triggers =
        resource
        |> AshOban.Info.oban_triggers()
        |> Enum.map(&describe(resource, &1))

      schedules =
        resource
        |> AshOban.Info.oban_scheduled_actions()
        |> Enum.map(&describe(resource, &1))

      {:ok, Enum.sort_by(triggers ++ schedules, &{&1.kind, &1.name})}
    else
      {:error, %{reason: :ash_oban_not_configured, resource: resource, extension: AshOban}}
    end
  end

  @doc "Looks up one configured activation by name."
  @spec fetch_activation(module(), atom()) :: {:ok, map()} | {:error, map()}
  def fetch_activation(resource, name) when is_atom(resource) and is_atom(name) do
    with {:ok, activations} <- activations(resource) do
      case Enum.find(activations, &(&1.name == name)) do
        nil -> {:error, %{reason: :unknown_ash_oban_activation, resource: resource, name: name}}
        activation -> {:ok, activation}
      end
    end
  end

  @doc """
  Describes one already-resolved AshOban trigger or scheduled action.

  `configuration` preserves every public struct field except Spark bookkeeping,
  while the grouped views expose the dimensions planners most often need:
  eligibility, activation, delivery, authority/context, failure handling and
  batching. Functions remain runtime terms; this descriptor is not a serialized
  receipt.
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
        |> Map.put(:job_controls, [:retry, :snooze, :cancel, :trigger_no_longer_applies]),
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
      failure: %{job_controls: [:retry, :snooze, :cancel], last_attempt_argument?: true},
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
  def construct_trigger(%resource{} = record, trigger, opts \\ []) when is_list(opts) do
    case resolve_trigger(resource, trigger) do
      nil ->
        {:error,
         %{reason: :unknown_ash_oban_trigger, resource: resource, trigger: trigger}}

      %AshOban.Trigger{} = resolved ->
        {:ok, AshOban.build_trigger(record, resolved, opts)}
    end
  end

  @doc "Classifies an AshOban/Oban public return or error as a bounded planner observation."
  @spec observation(term()) :: map()
  def observation(:ok), do: %{state: :succeeded, terminal?: true}
  def observation({:ok, value}), do: %{state: :succeeded, terminal?: true, value: value}

  def observation({:snooze, seconds}) when is_integer(seconds) do
    %{state: :snoozed, terminal?: false, retryable?: true, snooze_for: seconds}
  end

  def observation({:cancel, reason}) do
    %{state: :cancelled, terminal?: true, retryable?: false, reason: reason}
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

  @doc "Summarizes the AshOban capabilities present on one resource."
  @spec capabilities(module()) :: {:ok, map()} | {:error, map()}
  def capabilities(resource) when is_atom(resource) do
    with {:ok, activations} <- activations(resource) do
      triggers = Enum.filter(activations, &(&1.kind == :trigger))
      schedules = Enum.filter(activations, &(&1.kind == :scheduled_action))

      {:ok,
       %{
         owner: AshOban,
         resource: resource,
         triggers: Enum.map(triggers, & &1.name),
         scheduled_actions: Enum.map(schedules, & &1.name),
         conditional_activation?: triggers != [],
         temporal_activation?:
           schedules != [] || Enum.any?(triggers, &(not is_nil(&1.activation.scheduler_cron))),
         actor_persistence?:
           Enum.any?(activations, &(not is_nil(Map.get(&1.authority, :actor_persister)))),
         tenant_fanout?:
           Enum.any?(activations, &(not is_nil(Map.get(&1.authority, :list_tenants)))),
         tenant_from_record?:
           Enum.any?(triggers, &Map.get(&1.authority, :use_tenant_from_record?, false)),
         shared_context?:
           Enum.any?(activations, &(not is_nil(Map.get(&1.authority, :shared_context)))),
         chunk_processing?: Enum.any?(triggers, &(not is_nil(&1.batching))),
         trigger_once?: Enum.any?(triggers, &Map.get(&1.delivery, :trigger_once?, false)),
         on_error_actions?: Enum.any?(triggers, &(not is_nil(Map.get(&1.failure, :on_error)))),
         job_controls: [:retry, :snooze, :cancel],
         planner_outcomes: @outcome_states
       }}
    end
  end

  defp resource_uses_extension?(resource) do
    Spark.Dsl.is?(resource, Ash.Resource) && AshOban in Spark.extensions(resource)
  end

  defp resolve_trigger(_resource, %AshOban.Trigger{} = trigger), do: trigger
  defp resolve_trigger(resource, name) when is_atom(name), do: AshOban.Info.oban_trigger(resource, name)
  defp resolve_trigger(_resource, _trigger), do: nil

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
