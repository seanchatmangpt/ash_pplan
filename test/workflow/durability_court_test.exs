defmodule AshPPlan.Workflow.DurabilityCourtTest do
  @moduledoc """
  Durability Court: a run parked in the ledger engine and replayed by a later attempt keeps its
  semantic identity (subject, task, IRI, workflow) intact. Anti-vacuity: a run of a different
  workflow carries a different identity, and a non-portable (runtime-only) term is refused by the
  portability gate rather than recorded.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Clock, Engine, Portable, Run, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.{DurableFx, Effects}
  alias AshPPlan.Workflow.{Evidence, Model, Subject}

  setup do
    DurableFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    {:ok, _} = Effects.start_link()
    {:ok, store} = Ets.start_link()
    {:ok, store: store}
  end

  defp start(store, id, model \\ DurableFx.model()) do
    attrs =
      id
      |> DurableFx.attrs()
      |> Map.put(:model, model)
      |> Map.put(:context, %{run_id: id})

    {:ok, rec} = Engine.start(store, attrs)
    rec
  end

  defp identities(record) do
    {:ok, reactor} = Run.reactor_for(record)
    assert reactor.id == Evidence.plan_iri(Subject.bind(record.model).id)
    reactor.context[AshPPlan.Reactor.context_key()]
  end

  test "replayed run keeps its semantic identity", %{store: store} do
    rec = start(store, "dur-1")
    subject = Subject.bind(rec.model)
    assert {:parked, _} = Engine.attempt(store, "dur-1")

    # A later attempt rebuilds the reactor from the stored row alone.
    stored = Engine.fetch(store, "dur-1")
    identity = identities(stored)
    assert identity.subject == subject.id
    assert identity.workflow == to_string(rec.model.name)

    {:ok, _} = Engine.signal(store, "dur-1", DurableFx.signal_name(), :approved)
    assert {:completed, _} = Engine.attempt(store, "dur-1")
    assert Testing.status(store, "dur-1") == :completed
  end

  test "replay re-emits subject-bound telemetry", %{store: store} do
    rec = start(store, "dur-tel-1")
    subject = Subject.bind(rec.model)

    test_pid = self()
    handler = "dur-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      Evidence.telemetry_event(),
      fn _e, _m, md, _c -> send(test_pid, {:ev, md}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:parked, _} = Engine.attempt(store, "dur-tel-1")
    {:ok, _} = Engine.signal(store, "dur-tel-1", DurableFx.signal_name(), :approved)
    {:completed, _} = Engine.attempt(store, "dur-tel-1")

    assert_receive {:ev, %{subject_id: id, status: :succeeded, run_id: "dur-tel-1"}}
    assert id == subject.id
  end

  test "a different workflow's run carries a different identity (anti-vacuity)", %{store: store} do
    other = %{DurableFx.model() | name: "qualified_fulfillment_durable_spine_b"}
    a = start(store, "dur-a")
    b = start(store, "dur-b", other)

    refute Subject.bind(a.model).id == Subject.bind(b.model).id
    ia = identities(a)
    ib = identities(b)
    refute ia.subject == ib.subject
    assert ia.workflow != ib.workflow
  end

  test "a runtime-only term is refused by the portability gate, not recorded" do
    refute Portable.portable?(%{owner: self()})
    assert {:error, :non_portable_runtime_term} = Portable.check({:ok, make_ref()})
    assert :ok = Portable.check(%{order: "o-1", at: ~U[2026-01-01 00:00:00Z]})
  end

  test "model validity is preserved by the fixture" do
    assert {:ok, _} = Model.new(Map.from_struct(DurableFx.model()) |> Map.to_list())
  end
end
