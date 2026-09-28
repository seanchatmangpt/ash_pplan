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

  test "resolves one resource descriptor without executing jobs" do
    resource = AshPPlan.ObanIntegrationResource

    assert {:ok, descriptor} = ObanProjection.describe_resource(resource)
    assert descriptor.owner == AshOban
    assert descriptor.authority.inspect == AshOban.Info
    assert descriptor.authority.construct == AshOban
    assert descriptor.authority.queue_runtime == Oban

    assert Enum.map(descriptor.activations, &{&1.kind, &1.name}) == [
             {:scheduled_action, :tick},
             {:trigger, :process}
           ]

    capabilities = descriptor.capabilities
    assert capabilities.conditional_activation?
    assert capabilities.temporal_activation?
    assert capabilities.retry_delivery?
    assert capabilities.shared_context?
    assert capabilities.stable_worker_identity?
    assert capabilities.stable_scheduler_identity?
    refute capabilities.actor_persistence?
    refute capabilities.default_actor?
    refute capabilities.tenant_fanout?
    refute capabilities.tenant_from_record?
    refute capabilities.chunk_processing?
  end

  test "fetches resolved activation through the same descriptor boundary" do
    resource = AshPPlan.ObanIntegrationResource

    assert {:ok, trigger} = ObanProjection.fetch_activation(resource, :process)
    assert trigger.delivery.max_attempts == 3
    assert trigger.delivery.backoff == 15
    assert trigger.activation.scheduler_cron == false
    assert trigger.authority.shared_context == [:job]
  end

  test "constructs a trigger job without inserting it" do
    resource = AshPPlan.ObanIntegrationResource
    record = struct(resource, id: Ash.UUID.generate(), processed: false)

    assert {:ok, changeset} = ObanProjection.construct_trigger(record, :process)
    assert changeset.valid?
    refute is_nil(Ecto.Changeset.get_field(changeset, :worker))
  end

  describe "observation/1 over Oban worker results" do
    test "classifies success returns" do
      assert %{state: :succeeded, terminal?: true} = ObanProjection.observation(:ok)

      assert %{state: :succeeded, terminal?: true, value: :done} =
               ObanProjection.observation({:ok, :done})
    end

    test "classifies integer and period snoozes" do
      assert %{state: :snoozed, terminal?: false, snooze_for: 60} =
               ObanProjection.observation({:snooze, 60})

      assert %{state: :snoozed, terminal?: false, retryable?: true, snooze_for: {5, :minutes}} =
               ObanProjection.observation({:snooze, {5, :minutes}})

      assert %{state: :snoozed, snooze_for: {1, :hour}} =
               ObanProjection.observation({:snooze, {1, :hour}})
    end

    test "does not admit malformed snooze periods" do
      assert %{state: :unknown} = ObanProjection.observation({:snooze, {5, :fortnights}})
      assert %{state: :unknown} = ObanProjection.observation({:snooze, -1})
    end

    test "classifies deprecated discard results as cancellation" do
      assert %{state: :cancelled, terminal?: true, retryable?: false, deprecated: :discard} =
               ObanProjection.observation(:discard)

      assert %{state: :cancelled, terminal?: true, reason: :bad_input, deprecated: :discard} =
               ObanProjection.observation({:discard, :bad_input})
    end

    test "classifies AshOban control errors wrapped in Ash errors" do
      snooze = AshOban.Errors.SnoozeJob.exception(snooze_for: 30)
      cancel = AshOban.Errors.CancelJob.exception(reason: :gone)

      assert %{state: :snoozed, snooze_for: 30} =
               ObanProjection.observation({:error, Ash.Error.to_error_class(snooze)})

      assert %{state: :cancelled, reason: :gone} =
               ObanProjection.observation({:error, Ash.Error.to_error_class(cancel)})

      assert %{state: :cancelled, reason: :gone} = ObanProjection.observation(cancel)
      assert %{state: :unknown, value: 42} = ObanProjection.observation(42)
    end
  end

  describe "resolved capability descriptors" do
    alias AshPPlan.DescriptorFixtures

    test "an empty oban section claims no activation or identity capability" do
      assert {:ok, descriptor} = ObanProjection.describe_resource(DescriptorFixtures.EmptyOban)
      assert descriptor.activations == []

      capabilities = descriptor.capabilities

      for key <- [
            :conditional_activation?,
            :temporal_activation?,
            :retry_delivery?,
            :job_controls_supported?,
            :actor_persistence?,
            :default_actor?,
            :tenant_fanout?,
            :tenant_from_record?,
            :shared_context?,
            :chunk_processing?,
            :trigger_once?,
            :on_error_actions?,
            :stable_worker_identity?,
            :stable_scheduler_identity?,
            :paused_or_deleted_activation?
          ] do
        refute Map.fetch!(capabilities, key), "#{key} claimed over no activations"
      end
    end

    test "a schedule-only resource claims no scheduler identity and no [nil] tenant fan-out" do
      assert {:ok, capabilities} =
               ObanProjection.capabilities(DescriptorFixtures.ScheduleOnlyOban)

      assert capabilities.temporal_activation?
      assert capabilities.stable_worker_identity?
      refute capabilities.conditional_activation?
      refute capabilities.stable_scheduler_identity?
      refute capabilities.tenant_fanout?
    end

    test "reads tenant fan-out and default actor from resolved configuration" do
      resource = DescriptorFixtures.SectionTenantsOban

      assert AshOban.Info.oban_trigger(resource, :process).list_tenants == nil
      assert AshOban.Info.oban_list_tenants!(resource) == ["tenant_a", "tenant_b"]

      assert {:ok, capabilities} = ObanProjection.capabilities(resource)
      assert capabilities.tenant_fanout?
      assert capabilities.default_actor?

      assert {:ok, activation} = ObanProjection.fetch_activation(resource, :process)
      assert activation.authority.list_tenants == nil
      assert activation.authority.resolved_list_tenants == ["tenant_a", "tenant_b"]
    end

    test "reads tenant-from-record configuration" do
      assert {:ok, capabilities} =
               ObanProjection.capabilities(DescriptorFixtures.TenantFromRecordOban)

      assert capabilities.tenant_from_record?
      refute capabilities.tenant_fanout?
    end

    test "a deleted trigger is visible but grants no live activation capability" do
      resource = DescriptorFixtures.DeletedTriggerOban

      assert {:ok, descriptor} = ObanProjection.describe_resource(resource)
      assert [%{name: :retire, active?: false}] = descriptor.activations

      capabilities = descriptor.capabilities
      assert capabilities.paused_or_deleted_activation?
      assert capabilities.stable_worker_identity?
      assert capabilities.stable_scheduler_identity?
      refute capabilities.conditional_activation?
      refute capabilities.temporal_activation?
      refute capabilities.retry_delivery?
      refute capabilities.job_controls_supported?
    end
  end

  describe "construct_trigger/3 refusals" do
    test "refuses structs that are not Ash resources" do
      assert {:error, %{reason: :not_an_ash_resource, resource: URI}} =
               ObanProjection.construct_trigger(%URI{}, :process)
    end

    test "refuses resources without AshOban" do
      record = %AshPPlan.DescriptorFixtures.PlainResource{id: Ash.UUID.generate()}

      assert {:error, %{reason: :ash_oban_not_configured}} =
               ObanProjection.construct_trigger(record, :process)
    end

    test "refuses unknown triggers and scheduled actions" do
      record = struct(AshPPlan.ObanIntegrationResource, id: Ash.UUID.generate())

      assert {:error, %{reason: :unknown_ash_oban_trigger, trigger: :missing}} =
               ObanProjection.construct_trigger(record, :missing)

      assert {:error, %{reason: :unknown_ash_oban_trigger, trigger: :tick}} =
               ObanProjection.construct_trigger(record, :tick)
    end

    test "refuses a trigger struct that belongs to another resource" do
      foreign =
        AshOban.Info.oban_trigger(AshPPlan.DescriptorFixtures.SectionTenantsOban, :process)

      record = struct(AshPPlan.ObanIntegrationResource, id: Ash.UUID.generate())

      assert {:error, %{reason: :foreign_ash_oban_trigger, trigger: :process}} =
               ObanProjection.construct_trigger(record, foreign)
    end

    test "accepts the resource's own resolved trigger struct without inserting" do
      resource = AshPPlan.ObanIntegrationResource
      record = struct(resource, id: Ash.UUID.generate(), processed: false)
      own = AshOban.Info.oban_trigger(resource, :process)

      assert {:ok, %Ecto.Changeset{} = changeset} = ObanProjection.construct_trigger(record, own)
      assert changeset.valid?
      assert changeset.action == nil
      assert Ecto.Changeset.get_field(changeset, :id) == nil

      assert Ecto.Changeset.get_field(changeset, :worker) ==
               inspect(AshPPlan.ObanIntegrationResource.ProcessWorker)
    end

    test "refuses non-struct records and non-list options" do
      assert {:error, %{reason: :invalid_ash_oban_construction}} =
               ObanProjection.construct_trigger(%{id: 1}, :process)

      record = struct(AshPPlan.ObanIntegrationResource, id: Ash.UUID.generate())

      assert {:error, %{reason: :invalid_ash_oban_construction}} =
               ObanProjection.construct_trigger(record, :process, %{})
    end
  end
end
