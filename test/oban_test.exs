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
end
