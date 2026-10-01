defmodule AshPPlan.Workflow.QualifiedFulfillmentDurableTest do
  @moduledoc """
  Durable halt/kill/resume court for the qualified-fulfillment human release.

  Real Reactor, real files in a tmp dir, real OTP processes. The runner is
  killed after the halt and a fresh runner resumes from the file store. Effect
  counters live in an Agent outside the runner; every consequential effect must
  have executed exactly once. Anti-vacuity: a naive restart that re-runs from
  scratch (no continuation) double-counts effects, and a corrupted store file
  is refused.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Examples.QualifiedFulfillment.{Durable, Followup}
  alias AshPPlan.Examples.QualifiedFulfillment.Durable.Counters

  setup do
    dir = Path.join(System.tmp_dir!(), "qf-durable-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, counters} = Counters.start_link()
    {:ok, dir: dir, counters: counters}
  end

  defp runner(ctx) do
    {:ok, pid} = Durable.start_link(dir: ctx.dir, counters: ctx.counters)
    pid
  end

  test "halt, kill, restart, resume approved: no consequential effect repeats", ctx do
    r1 = runner(ctx)
    assert {:halted, id} = Durable.run(r1, "run-1", "order-7")
    assert Counters.all(ctx.counters) == %{admit: 1, authorize: 1, release_poll: 1}
    assert File.exists?(Path.join(ctx.dir, "#{id}.continuation"))

    assert :ok = Durable.kill(r1)
    refute Process.alive?(r1)

    r2 = runner(ctx)
    assert {:ok, {:shipment_committed, "order-7"}} = Durable.resume(r2, id, :approved)

    counts = Counters.all(ctx.counters)
    assert counts.admit == 1
    assert counts.authorize == 1
    assert counts.commit == 1
  end

  test "refused release commits nothing", ctx do
    r1 = runner(ctx)
    {:halted, id} = Durable.run(r1, "run-2", "order-8")
    Durable.kill(r1)

    assert {:error, _} = Durable.resume(runner(ctx), id, :refused)
    assert Counters.count(ctx.counters, :commit) == 0
    assert Counters.count(ctx.counters, :admit) == 1
  end

  test "anti-vacuity: restart without the continuation repeats effects", ctx do
    r1 = runner(ctx)
    {:halted, _} = Durable.run(r1, "run-3", "order-9")
    Durable.kill(r1)
    {:halted, _} = Durable.run(runner(ctx), "run-3b", "order-9")
    assert Counters.count(ctx.counters, :admit) == 2
  end

  test "corrupted store file is refused on resume", ctx do
    r1 = runner(ctx)
    {:halted, id} = Durable.run(r1, "run-4", "order-10")
    Durable.kill(r1)

    {:ok, c} = Durable.Store.fetch(id, %{dir: ctx.dir})
    forged = %{c | payload: c.payload <> "x"}
    File.write!(Path.join(ctx.dir, "#{id}.continuation"), :erlang.term_to_binary(forged))

    assert {:error, %{reason: :continuation_payload_digest_mismatch}} =
             Durable.resume(runner(ctx), id, :approved)

    assert Counters.count(ctx.counters, :commit) == 0
  end

  test "followup job carries the continuation reference and runs the check", ctx do
    r1 = runner(ctx)
    {:halted, id} = Durable.run(r1, "run-5", "order-11")
    Durable.kill(r1)
    {:ok, _} = Durable.resume(runner(ctx), id, :approved)

    assert {:ok, %{record: record, job: job}} = Followup.schedule(id)
    assert record.continuation_ref == id
    assert job.valid?
    assert %{primary_key: _} = Ecto.Changeset.get_field(job, :args)

    assert {:ok, checked} =
             record
             |> Ash.Changeset.for_update(:check_delivery_status, %{}, domain: Followup.Domain)
             |> Ash.update()

    assert checked.checked
    assert checked.continuation_ref == id
  end
end
