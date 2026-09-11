defmodule AshPPlan.ObanIntegrationDomain do
  use Ash.Domain
end

defmodule AshPPlan.ObanIntegrationResource do
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshOban]

  oban do
    domain(AshPPlan.ObanIntegrationDomain)
    shared_context([:job])

    triggers do
      trigger :process do
        action(:process)
        where(expr(processed != true))
        scheduler_cron(false)
        max_attempts(3)
        backoff(15)
        worker_read_action(:read)
        worker_module_name(AshPPlan.ObanIntegrationResource.ProcessWorker)
      end
    end

    scheduled_actions do
      schedule :tick, "0 * * * *" do
        action(:tick)
        worker_module_name(AshPPlan.ObanIntegrationResource.TickWorker)
      end
    end
  end

  actions do
    default_accept(:*)

    read :read do
      primary?(true)
      pagination(keyset?: true)
    end

    create(:tick)

    update :process do
      change(set_attribute(:processed, true))
    end
  end

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:processed, :boolean, default: false, allow_nil?: false)
  end
end

defmodule AshPPlan.ObanTest do
  use ExUnit.Case, async: true

  alias AshPPlan.Oban, as: ObanProjection

  test "describes the complete resolved trigger capability surface" do
    trigger = %AshOban.Trigger{
      name: :process,
      action: :process,
      where: :eligible,
      sort: [:id],
      read_action: :read,
      worker_read_action: :worker_read,
      record_limit: 50,
      stream_batch_size: 20,
      stream_with: :keyset,
      lock_for_update?: true,
      scheduler_cron: "*/5 * * * *",
      scheduler_queue: :scheduler,
      scheduler_priority: 3,
      queue: :work,
      worker_priority: 1,
      max_attempts: 5,
      max_scheduler_attempts: 2,
      trigger_once?: true,
      backoff: 30,
      timeout: 10_000,
      tags: ["billing"],
      list_tenants: ["one", "two"],
      actor_persister: ExampleActorPersister,
      default_actor: :system,
      shared_context: [:job],
      use_tenant_from_record?: true,
      action_input: %{source: :planner},
      on_error: :mark_failed,
      on_error_fails_job?: true,
      chunks: %AshOban.Chunks{size: 100, timeout: 5_000, by: [:shard_id]}
    }

    descriptor = ObanProjection.describe(ExampleResource, trigger)

    assert descriptor.kind == :trigger
    assert descriptor.owner == AshOban
    assert descriptor.eligibility.stream_with == :keyset
    assert descriptor.activation.scheduler_cron == "*/5 * * * *"
    assert descriptor.delivery.max_attempts == 5
    assert descriptor.delivery.trigger_once?
    assert descriptor.authority.list_tenants == ["one", "two"]
    assert descriptor.authority.use_tenant_from_record?
    assert descriptor.failure.on_error == :mark_failed
    assert descriptor.batching.size == 100
    assert descriptor.batching.automatic_partitions == [:actor, :tenant_when_multitenant]
    assert descriptor.batching.bulk_execution == [:update, :destroy]
  end

  test "describes scheduled actions without manufacturing trigger semantics" do
    schedule = %AshOban.Schedule{
      name: :import,
      action: :import,
      cron: "0 */6 * * *",
      action_input: %{provider: :github},
      list_tenants: [nil],
      queue: :imports,
      priority: 2,
      max_attempts: 3,
      state: :active,
      shared_context: [:job],
      tags: ["external"]
    }

    descriptor = ObanProjection.describe(ExampleResource, schedule)

    assert descriptor.kind == :scheduled_action
    assert descriptor.activation == %{cron: "0 */6 * * *", state: :active}
    assert descriptor.delivery.queue == :imports
    assert descriptor.failure.last_attempt_argument?
    assert descriptor.batching == nil
  end

  test "classifies snooze and cancel controls as bounded planner observations" do
    snooze = AshOban.Errors.SnoozeJob.exception(snooze_for: 60)
    cancel = AshOban.Errors.CancelJob.exception(reason: :record_deleted)

    assert %{state: :snoozed, terminal?: false, retryable?: true, snooze_for: 60} =
             ObanProjection.observation({:error, snooze})

    assert %{state: :cancelled, terminal?: true, retryable?: false} =
             ObanProjection.observation({:error, cancel})

    assert %{state: :failed, terminal?: false} =
             ObanProjection.observation({:error, :ordinary_failure})
  end

  test "preserves every resolved public field in configuration" do
    trigger = %AshOban.Trigger{
      name: :process,
      action: :process,
      queue: :work,
      worker_opts: [unique: [period: 300]],
      extra_args: %{shard_id: 7}
    }

    configuration = ObanProjection.describe(ExampleResource, trigger).configuration

    assert configuration.name == :process
    assert configuration.action == :process
    assert configuration.queue == :work
    assert configuration.worker_opts == [unique: [period: 300]]
    assert configuration.extra_args == %{shard_id: 7}
    refute Map.has_key?(configuration, :__spark_metadata__)
  end

  test "introspects the real AshOban extension without executing jobs" do
    resource = AshPPlan.ObanIntegrationResource

    assert {:ok, activations} = ObanProjection.activations(resource)

    assert Enum.map(activations, &{&1.kind, &1.name}) == [
             {:scheduled_action, :tick},
             {:trigger, :process}
           ]

    assert {:ok, trigger} = ObanProjection.fetch_activation(resource, :process)
    assert trigger.delivery.max_attempts == 3
    assert trigger.delivery.backoff == 15
    assert trigger.activation.scheduler_cron == false
    assert trigger.authority.shared_context == [:job]

    assert {:ok, capabilities} = ObanProjection.capabilities(resource)
    assert capabilities.conditional_activation?
    assert capabilities.temporal_activation?
    assert capabilities.shared_context?
  end

  test "constructs a trigger job without inserting it" do
    resource = AshPPlan.ObanIntegrationResource
    record = struct(resource, id: Ash.UUID.generate(), processed: false)

    assert {:ok, changeset} = ObanProjection.construct_trigger(record, :process)
    assert changeset.valid?
    refute is_nil(Ecto.Changeset.get_field(changeset, :worker))
  end
end
