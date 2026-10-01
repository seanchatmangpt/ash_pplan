defmodule AshPPlan.Reactor.Durable.LedgerOCELTest do
  @moduledoc """
  Court: a durable run's standing checkpoint ledger exports as OCEL 2.0 evidence bound to
  the workflow subject, and the export is tamper-evident.

  Real engine + real Store.Ets + real Reactor steps (the LaneBFx fixture), no mocks.
  Mutations (each flips a named test): (1) exporting the output a step *produced* instead
  of the output that *stands* changes the evidence digest; (2) dropping the subject lookup
  leaves every event subject-less, which the subject-binding assertions catch.
  """
  use ExUnit.Case, async: false

  Code.require_file("lane_b_fixture.exs", __DIR__)

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.{Clock, Engine, LedgerOCEL}
  alias AshPPlan.Test.DurableFx
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Effects

  @subject "sha256:" <> String.duplicate("ab", 32)

  setup do
    LaneBFx.install_adapter!()
    DurableFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    {:ok, _} = Effects.start_link()
    {:ok, _} = Effects.start_link(name: :fx_ledger)
    {:ok, store} = Ets.start_link()
    {:ok, store: store}
  end

  defp start_run(store, id) do
    attrs =
      id
      |> LaneBFx.attrs(:fx_ledger)
      |> Map.update!(:context, fn c ->
        Map.put(c, :ash_pplan_workflow, %{subject: @subject, task: "ledger_test"})
      end)

    {:ok, _rec} = Engine.start(store, attrs)
    assert {:completed, _} = Engine.attempt(store, id)
  end

  test "exports the standing ledger as subject-bound OCEL evidence", %{store: store} do
    start_run(store, "locel1")

    assert {:ok, events} = LedgerOCEL.events(store, "locel1")
    assert {:ok, json} = LedgerOCEL.export(store, "locel1")
    assert is_binary(json) and json =~ "\"events\""

    # one started + one per standing checkpoint (5 steps) + one ended
    assert length(events) == 7
    assert [%{activity: "run_started"} | _] = events
    assert [%{activity: "run_ended"} | _] = events |> Enum.reverse()

    for e <- events do
      assert e.subject_id == @subject
      assert %DateTime{} = e.timestamp
    end

    assert Enum.any?(
             events,
             &(&1.activity == "task_succeeded" and &1.attributes[:task] =~ "#step-execute")
           )
  end

  test "unknown run is a typed refusal", %{store: store} do
    assert {:error, %{reason: :no_such_run}} = LedgerOCEL.events(store, "ghost")
  end

  test "digest is tamper-evident over standing outputs", %{store: store} do
    # A parked (non-terminal) run: the undo path is lawful here, so the standing set can
    # legitimately change under us — and the digest must track it.
    attrs =
      "locel3"
      |> DurableFx.attrs()
      |> Map.update!(:context, fn c ->
        Map.put(c, :ash_pplan_workflow, %{subject: @subject, task: "ledger_test"})
      end)

    {:ok, _rec} = Engine.start(store, attrs)
    assert {:parked, :waiting} = Engine.attempt(store, "locel3")

    assert {:ok, d1} = LedgerOCEL.digest(store, "locel3")

    key =
      AshPPlan.Reactor.Durable.Key.for_name(
        "urn:ash-pplan:workflow:qualified_fulfillment_durable_spine#step-admit_order"
      )

    assert {:ok, _cp} = Ets.claim_undo(store, "locel3", key, Clock.now())

    assert {:ok, d2} = LedgerOCEL.digest(store, "locel3")
    refute d1 == d2
  end
end
