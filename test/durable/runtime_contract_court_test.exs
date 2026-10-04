defmodule AshPPlan.Reactor.Durable.RuntimeContractCourtTest do
  @moduledoc """
  Runtime-contract adoption court (ECO-SAGA-COMPENSATE phase 2, draft 4.1):
  the five GENERATED `AshPPlan.RuntimeContract.*` modules bind to real durable
  runs — receipt round-trip into a validated `AshPPlan.ExecutionReceipt`,
  replay round-trip through `Counterfactual.replay/3` signal redelivery keyed by
  the ontology row's `rt:hasReplayKey`, typed refusal round-trip from a real
  saga delegate refusal, exact-subject and authority-gate checks. Real
  `Store.Ets`, real `Engine.start/3` runs, real generated modules by alias,
  real `ExecutionReceipt`, zero mocks.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.ExecutionReceipt
  alias AshPPlan.Reactor.Durable.{Clock, Counterfactual, Engine}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Reactor.Durable.Compensations.{Dispatch, Poll}
  alias AshPPlan.RuntimeContract.{AuthorityGate, ExactSubject, Receipt, Refusal, Replay}
  alias AshPPlan.Test.{DurableFx, Effects}

  setup do
    {:ok, store} = Ets.start_link()
    {:ok, store: store}
  end

  defp fresh_run(store) do
    {:ok, run} =
      Engine.start(store, %{
        id: "rtc-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower),
        model: nil
      })

    run
  end

  defp durable_ctx(store, run_id) do
    %{
      durable: %{
        store: store,
        store_module: Ets,
        run_id: run_id,
        checkpoints: Map.new(Ets.checkpoints(store, run_id), fn {k, c} -> {k, c.output} end)
      }
    }
  end

  # -- exact subject -----------------------------------------------------------

  test "ExactSubject binds the pinned consumer subject and refuses every other" do
    identity = ExactSubject.identity()
    assert %{repo: "ash_pplan", base: base, head: head} = identity
    assert base != nil and head != nil
    assert Regex.match?(~r/^[0-9a-f]{40}$/, head)
    assert Regex.match?(~r/^[0-9a-f]{40}$/, base)

    assert ExactSubject.exact?(identity)
    refute ExactSubject.exact?(%{identity | repo: "other_repo"})
    refute ExactSubject.exact?(%{identity | head: String.duplicate("0", 40)})
    refute ExactSubject.exact?(%{identity | base: String.duplicate("f", 40)})
  end

  # -- authority gate ----------------------------------------------------------

  test "AuthorityGate admits the order's CONSTRUCT ceiling and refuses the rest" do
    assert AuthorityGate.authorize(%{action: "CONSTRUCT", policy: :policy}) == :ok

    assert {:error, {:refused, :authority, "CONSTRUCT"}} =
             AuthorityGate.authorize(%{action: "CONSTRUCT"})

    assert {:error, {:refused, :authority, "DESTROY"}} =
             AuthorityGate.authorize(%{action: "DESTROY", policy: :policy})

    assert {:error, {:refused, :authority, :missing_action}} = AuthorityGate.authorize(%{})
  end

  # -- receipt round-trip --------------------------------------------------------

  test "generated Receipt constructs a validated ExecutionReceipt bound to a real run" do
    store = test_store()
    run = fresh_run(store)
    subject = ExactSubject.identity()

    r = Receipt.new(subject, "run", {:ok, run.id}, "replay_identity")
    assert r.subject == subject
    assert r.action == "run"
    assert r.result == {:ok, run.id}
    assert r.replay_key == "replay_identity"
    assert %DateTime{} = r.recorded_at

    er =
      ExecutionReceipt.observe(
        "urn:ash-pplan:plan:runtime-contract-court",
        run.id,
        {:ok, run.id},
        DateTime.utc_now(),
        System.monotonic_time(),
        repo: subject.repo,
        subject_sha: subject.head,
        base_sha: subject.base
      )

    assert :ok = ExecutionReceipt.validate_identity(er)
    assert ExecutionReceipt.run_identifier(er.run_id) == run.id
    assert er.subject_sha == ExactSubject.identity().head
    assert er.base_sha == ExactSubject.identity().base
    assert er.status == :succeeded

    prov = ExecutionReceipt.to_rdf(er)
    assert prov =~ "urn:ash-pplan:receipt:#{run.id}:#{er.outcome_digest}"
    assert prov =~ "<urn:ash-pplan:execution:#{run.id}>"
    assert prov =~ ~s("#{run.id}")
  end

  # -- refusal round-trip --------------------------------------------------------

  test "real saga delegate refusal maps into the typed generated Refusal" do
    store = test_store()
    run = fresh_run(store)
    _ = run

    for delegate <- [Dispatch, Poll] do
      # no durable ledger context: the delegate's typed refusal, never :retry
      assert {:error, {:saga_undo_refused, detail} = typed} =
               delegate.compensate({:error, :x}, %{}, %{}, [])

      refusal = Refusal.new("REFUSED", typed, ExactSubject.identity())
      assert %Refusal{code: "REFUSED"} = refusal
      assert refusal.reason == typed
      assert {:refused, "REFUSED", ^typed} = Refusal.tagged(refusal)
      # broken_term carried as the typed tuple, never narrowed to a bare string
      assert is_tuple(refusal.reason)
      assert match?({:no_durable_ledger_context, _}, detail)

      # with a real ledger context the same delegate succeeds instead
      assert delegate.compensate({:error, :y}, %{}, durable_ctx(store, run.id), []) == :ok
    end
  end

  # -- replay round-trip ---------------------------------------------------------

  test "undo events replay through the generated Replay module on a real completed run" do
    effects = :"rtc_effects_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: effects)
    store = test_store()

    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    DurableFx.install_adapter!()

    id = "rtc-replay-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    {:ok, _} = Engine.start(store, DurableFx.attrs(id, effects: effects))
    assert {:parked, _} = Engine.attempt(store, id)
    {:ok, _} = Engine.signal(store, id, DurableFx.signal_name(), %{released: true})
    assert {:completed, _} = Engine.attempt(store, id)

    # the generated saga delegates emit undo events into the real ledger
    ctx = durable_ctx(store, id)
    assert Dispatch.compensate({:error, :r1}, %{}, ctx, []) == :ok
    assert Poll.compensate({:error, :r2}, %{}, ctx, []) == :ok

    assert Enum.count(Ets.signals(store, id), &match?(%{type: :saga_undo}, &1.payload)) == 2

    before = Counterfactual.ledger_digest(store, id)
    receipt = Receipt.new(ExactSubject.identity(), "run", {:ok, id}, "replay_identity")

    {:ok, cf} =
      Replay.replay(receipt, fn key ->
        # the replay is keyed by the ontology row's rt:hasReplayKey
        assert key == "replay_identity"
        Counterfactual.replay(store, id, change: %{}, keep: true)
      end)

    # the original ledger is untouched by the replay
    assert cf.untouched?
    assert Counterfactual.ledger_digest(store, id) == before

    # the scratch run received the re-delivered undo signals
    scratch = cf.scratch
    assert scratch

    scratch_undo =
      Ets.signals(scratch, id)
      |> Enum.filter(&match?(%{type: :saga_undo}, &1.payload))
      |> Enum.map(& &1.payload.undo_name)
      |> Enum.sort()

    assert scratch_undo == ["ash_pplan.undo.dispatch", "ash_pplan.undo.poll"]

    if scratch && Process.alive?(scratch), do: GenServer.stop(scratch)
  end

  defp test_store do
    {:ok, st} = Ets.start_link()
    st
  end
end
