defmodule AshPPlan.Reactor.Durable.DurableEnginePm4Test do
  @moduledoc """
  Process-conformance courts for the durable engine, validated with pm4exunit over traces whose
  every event is emitted immediately after the real engine/store call that observably produced
  it (return value, ledger row, clock reading, effect counter). Timestamps are the injectable
  `Durable.Clock`, never wall time.

  Collaborators are real: `Store.Ets`, `Engine`, Reactor, the `LaneBFx` fixture and the
  `Effects` counter agent. No mocks, no sleeps.

  The one derived (counterfactual) trace is the duplicated-effect trace: it is computed from the
  real result list of a real concurrent double claim by replaying it through an unfenced
  executor (one effect per claim attempt, winner or not). The real, fenced trace conforms; the
  derived one must not.
  """
  use ExUnit.Case, async: false
  use Pm4ExUnit

  @moduletag :pm4exunit

  Code.require_file("../durable/lane_b_fixture.exs", __DIR__)

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Key, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Effects

  @id_key AshPPlan.Reactor.context_key()
  @unwind_log :pm4_unwind_log

  defmodule S do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(_a, _c, _o), do: {:ok, :done}

    @impl true
    def undo(_value, _args, _context, opts) do
      name = Keyword.fetch!(opts, :name)
      Agent.update(:pm4_unwind_log, fn order -> order ++ [name] end)
      :ok
    end
  end

  setup do
    LaneBFx.install_adapter!()
    Clock.use_test_clock(~U[2026-01-01 00:00:00Z])
    on_exit(&Clock.reset/0)
    fx = :"pm4_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)
    {:ok, store} = Ets.start_link()
    {:ok, store: store, fx: fx}
  end

  defp emit(session, activity) do
    id = "e#{System.unique_integer([:positive, :monotonic])}"
    emit_event(session, id, activity, timestamp: Clock.now())
  end

  test "await -> signal -> resume conforms to started/parked/signaled/resumed/completed", %{
    pm4_session: session,
    store: store,
    fx: fx
  } do
    {:ok, _} = Engine.start(store, LaneBFx.attrs("p1", fx, kinds: %{integrate: :await}))
    emit(session, :started)

    assert {:parked, :waiting} = Engine.attempt(store, "p1")
    assert Testing.status(store, "p1") == :waiting
    emit(session, :parked)

    {:ok, _} = Engine.signal(store, "p1", "go", :now)
    emit(session, :signaled)

    assert "p1" in Engine.runnable(store, Clock.now())
    emit(session, :resumed)

    assert [{"p1", {:completed, _}}] = Testing.drain(store)
    assert Testing.status(store, "p1") == :completed
    emit(session, :completed)

    model = [[:started, :parked, :signaled, :resumed, :completed]]
    assert_conformance(session, model)

    # the same real events, reordered so the signal precedes the park, violate the model
    reordered = [:started, :signaled, :parked, :resumed, :completed]
    refute_conformance(reordered, model)
  end

  test "a deadline-parked run wakes only once the injected clock reaches not_before", %{
    pm4_session: session,
    store: store,
    fx: fx
  } do
    {:ok, _} = Engine.start(store, LaneBFx.attrs("d1", fx, kinds: %{integrate: :await}))
    assert {:parked, :waiting} = Engine.attempt(store, "d1")

    not_before = Clock.add(Clock.now(), 1_000)
    {:ok, _} = Ets.park(store, "d1", "dl", :signal, not_before)
    emit(session, :parked)

    refute "d1" in Engine.runnable(store, Clock.now())
    emit(session, :refused_early)

    Clock.advance(999)
    refute "d1" in Engine.runnable(store, Clock.now())
    emit(session, :refused_early)

    Clock.advance(1)
    assert DateTime.compare(Clock.now(), not_before) == :eq
    assert "d1" in Engine.runnable(store, Clock.now())
    emit(session, :woke)

    assert_conformance(session, [[:parked, :refused_early, :refused_early, :woke]])

    # SLA on injected clock time: woke exactly 1s of clock time after parked, never earlier
    assert_sla(session, :parked, :woke, max_seconds: 1.5)

    [parked, woke] =
      for e <- Pm4ExUnit.Session.get_events(session), e.activity in ["parked", "woke"], do: e

    assert DateTime.diff(woke.timestamp, parked.timestamp, :millisecond) == 1_000
  end

  test "claim takeover after a dead claimer yields the effect exactly once", %{
    pm4_session: session,
    store: store,
    fx: fx
  } do
    {:ok, _} = Engine.start(store, LaneBFx.attrs("t1", fx))

    # claimer :a takes a 20ms lease and dies without releasing
    assert {:ok, rec} = Ets.claim(store, "t1", :a, 20, Clock.now())
    emit(session, :claimed)

    # while the lease is live, an attempt does no work
    first = Engine.attempt(store, "t1")
    refute match?({:completed, _}, first)
    assert LaneBFx.counts(fx) == %{}

    Clock.advance(60)
    assert DateTime.compare(Clock.now(), rec.lease_until) == :gt
    emit(session, :lease_expired)

    assert {:completed, _} = Engine.attempt(store, "t1")
    emit(session, :takeover)

    assert LaneBFx.counts(fx) == %{observe: 1, select: 1, execute: 1, integrate: 1, verify: 1}
    emit(session, :effect)

    # the dead claimer's late release cannot disturb the completed run
    assert :ok = Ets.release_claim(store, "t1", :a)
    assert Testing.status(store, "t1") == :completed
    emit(session, :completed)

    assert_conformance(session, [[:claimed, :lease_expired, :takeover, :effect, :completed]])
  end

  test "a real concurrent double claim: fenced trace conforms, derived duplicate trace does not",
       %{pm4_session: session, store: store, fx: fx} do
    {:ok, _} = Ets.start_run(store, %{id: "dc"})

    results =
      1..3
      |> Enum.map(fn i ->
        Task.async(fn -> Ets.claim(store, "dc", {:claimer, i}, 60_000, Clock.now()) end)
      end)
      |> Task.await_many(:infinity)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == :taken)) == 2

    # fenced executor: only the claim winner performs the effect
    emit(session, :claim_won)
    for r <- results, match?({:ok, _}, r), do: {:ok, _} = Effects.run(fx, :work)
    assert Effects.count(fx, :work) == 1
    for _ <- 1..Effects.count(fx, :work), do: emit(session, :effect)
    emit(session, :completed)

    model = [[:claim_won, :effect, :completed]]
    assert_conformance(session, model)

    # derived: unfenced replay of the same real results, one effect per claim attempt
    duplicated =
      [:claim_won] ++ Enum.map(results, fn _ -> :effect end) ++ [:completed]

    assert Enum.count(duplicated, &(&1 == :effect)) == 3
    refute_conformance(duplicated, model)
  end

  test "cancel unwinds in reverse order of completion", %{pm4_session: session, store: store} do
    {:ok, _} = Agent.start_link(fn -> [] end, name: @unwind_log)
    ctx = %{@id_key => %{subject: "sha256:pm4", workflow: :pm4}}
    {:ok, _} = Engine.start(store, %{id: "u1", context: ctx})

    for n <- [:a, :b, :c] do
      {:ok, _} =
        Ets.record(store, "u1", Key.for_name(n), Key.label(n), :out, %{
          impl: {S, [name: n]},
          args: %{}
        })
    end

    done =
      store
      |> Ets.standing("u1")
      |> Enum.reject(&Key.intent_row?/1)
      |> Enum.sort_by(& &1.seq)
      |> Enum.map(& &1.label)

    assert done == Enum.map([:a, :b, :c], &Key.label/1)
    for label <- done, do: emit(session, "done_" <> label)

    {:ok, _} = Engine.cancel(store, "u1")
    assert {:rolled_back, :cancelled} = Engine.attempt(store, "u1")
    assert Testing.status(store, "u1") == :cancelled

    undone = Agent.get(@unwind_log, & &1)
    assert Enum.sort(undone) == [:a, :b, :c]
    for n <- undone, do: emit(session, "undo_" <> Key.label(n))

    [la, lb, lc] = Enum.map([:a, :b, :c], &Key.label/1)

    model = [
      ["done_" <> la, "done_" <> lb, "done_" <> lc, "undo_" <> lc, "undo_" <> lb, "undo_" <> la]
    ]

    assert_conformance(session, model)

    # the same completions undone in completion order (not reverse) violate the model
    forward =
      Enum.map(done, &("done_" <> &1)) ++ Enum.map(done, &("undo_" <> &1))

    refute_conformance(forward, model)
  end
end
