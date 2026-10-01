defmodule AshPPlan.Durable.TLATraceTest do
  @moduledoc """
  Differential court: a real engine run (real `Store.Ets` behind a recording store wrapper,
  real Reactor, real counting steps) produces a trace that the protocol model accepts.

  The model side is `priv/tla/durable/transitions.exs`, generated from the same ontology that
  emits `DurableProtocol.tla`. It is also checked against `Status.can?/2` for every status
  pair, so ontology drift from the engine's own relation fails here. The trace checker enforces
  the model's safety claims on observed events: guarded status transitions, terminal
  absorbing, cancelling never overwritten, claim exclusive, each step recorded once, and a
  signal delivered to a parked run followed by an attempt (no lost wakeup).

  `RecordingStore` is a hand-written real implementation of the `Store` behaviour that delegates
  to `Store.Ets` and appends events; it is not a mock.

  Anti-vacuity mutations: remove the terminal-absorbing clause in `check/2` -> the
  completed->waiting corrupted trace is accepted and its test fails; remove the holder check in
  `:claim` -> the double-claim trace is accepted and its test fails.
  """
  use ExUnit.Case, async: false

  Code.require_file("lane_b_fixture.exs", __DIR__)

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Status}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Effects

  @model Code.eval_file(Path.expand("../../priv/tla/durable/transitions.exs", __DIR__)) |> elem(0)

  defmodule RecordingStore do
    @moduledoc false
    @behaviour AshPPlan.Reactor.Durable.Store
    alias AshPPlan.Reactor.Durable.Store.Ets

    defp log({_s, l}, ev), do: Agent.update(l, &[ev | &1])
    def events(l), do: l |> Agent.get(& &1) |> Enum.reverse()

    def start_run({s, _}, a), do: Ets.start_run(s, a)
    def get_run({s, _}, id), do: Ets.get_run(s, id)
    def list_runs({s, _}), do: Ets.list_runs(s)

    def transition({s, _} = st, id, from, to, attrs) do
      r = Ets.transition(s, id, from, to, attrs)
      with {:ok, rec} <- r, do: log(st, {:transition, id, rec.status})
      r
    end

    def claim({s, _} = st, id, claimer, lease, now) do
      r = Ets.claim(s, id, claimer, lease, now)
      log(st, {:claim, id, claimer, if(r == :taken, do: :taken, else: :ok)})
      r
    end

    def release_claim({s, _} = st, id, claimer) do
      log(st, {:release, id, claimer})
      Ets.release_claim(s, id, claimer)
    end

    def checkpoints({s, _}, id), do: Ets.checkpoints(s, id)
    def standing({s, _}, id), do: Ets.standing(s, id)

    def record({s, _} = st, id, key, label, out, meta) do
      r = Ets.record(s, id, key, label, out, meta)
      with {:ok, cp} <- r, do: log(st, {:record, id, key, cp.seq})
      r
    end

    def claim_undo({s, _}, id, key, now), do: Ets.claim_undo(s, id, key, now)
    def release_undo({s, _}, id, key), do: Ets.release_undo(s, id, key)

    def deliver_signal({s, _} = st, id, name, p) do
      r = Ets.deliver_signal(s, id, name, p)
      log(st, {:deliver, id, Ets.get_run(s, id) && Ets.get_run(s, id).status})
      r
    end

    def pending_signal({s, _}, id, n), do: Ets.pending_signal(s, id, n)
    def consume_signal({s, _}, sid, now), do: Ets.consume_signal(s, sid, now)
    def park({s, _}, id, n, k, d, o \\ []), do: Ets.park(s, id, n, k, d, o)
    def get_waiter({s, _}, id, n), do: Ets.get_waiter(s, id, n)
    def waiters({s, _}, id), do: Ets.waiters(s, id)
    def release({s, _}, id, n), do: Ets.release(s, id, n)
    def release_all({s, _}, id), do: Ets.release_all(s, id)
    def signals({s, _}, id), do: Ets.signals(s, id)
  end

  @doc false
  # Returns :ok or {:violation, kind, detail}. Pure over the event list and the generated model.
  def check(events, model \\ @model) do
    init = %{status: :pending, holder: nil, records: %{}, parked_signal: false}

    result =
      Enum.reduce_while(events, init, fn ev, st ->
        case step(ev, st, model) do
          {:ok, st} -> {:cont, st}
          {:violation, _, _} = v -> {:halt, v}
        end
      end)

    case result do
      {:violation, _, _} = v -> v
      %{parked_signal: true} -> {:violation, :lost_wakeup, :no_attempt_after_signal}
      _ -> :ok
    end
  end

  defp step({:transition, _id, to}, %{status: from} = st, model) do
    cond do
      from in model.terminal ->
        {:violation, :terminal_absorbing, {from, to}}

      from == :cancelling and to not in [:cancelled, :unwind_blocked] ->
        {:violation, :cancel_overwritten, {from, to}}

      {from, to} not in model.transitions and from != to ->
        {:violation, :illegal_transition, {from, to}}

      true ->
        {:ok, %{st | status: to}}
    end
  end

  defp step({:claim, _id, _c, :taken}, st, _), do: {:ok, st}

  defp step({:claim, _id, c, :ok}, %{holder: h} = st, _) do
    if h != nil and h != c,
      do: {:violation, :claim_exclusive, {h, c}},
      else: {:ok, %{st | holder: c, parked_signal: false}}
  end

  defp step({:release, _id, c}, %{holder: h} = st, _),
    do: {:ok, if(h == c, do: %{st | holder: nil}, else: st)}

  defp step({:record, _id, key, seq}, %{records: r} = st, _) do
    case r do
      %{^key => ^seq} -> {:ok, st}
      %{^key => other} -> {:violation, :double_effect, {key, other, seq}}
      _ -> {:ok, %{st | records: Map.put(r, key, seq)}}
    end
  end

  defp step({:deliver, _id, status}, st, _),
    do: {:ok, %{st | parked_signal: st.parked_signal or status in [:waiting, :polling]}}

  setup do
    LaneBFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    name = :"tla_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: name)
    {:ok, ets} = Ets.start_link()
    {:ok, log} = Agent.start_link(fn -> [] end)
    {:ok, store: {ets, log}, log: log, fx: name}
  end

  @opts [store_module: RecordingStore]

  # `Testing.drain/2` calls `Engine.runnable/2` without opts, so it cannot carry the
  # recording wrapper; the loop is duplicated here over the wrapper's own opts.
  defp drain(store, rounds \\ 50, acc \\ [])
  defp drain(_store, 0, acc), do: Enum.reverse(acc)

  defp drain(store, rounds, acc) do
    case Engine.runnable(store, Clock.now(), @opts) do
      [] ->
        Enum.reverse(acc)

      ids ->
        drain(
          store,
          rounds - 1,
          Enum.reverse(Enum.map(ids, &{&1, Engine.attempt(store, &1, @opts)}), acc)
        )
    end
  end

  test "generated status relation equals Status.can?/2 on every pair" do
    for from <- Status.all(), to <- Status.all() do
      assert {from, to} in @model.transitions == Status.can?(from, to),
             "ontology drift on #{from} -> #{to}"
    end

    assert Enum.sort(@model.statuses) == Enum.sort(Status.all())
    assert Enum.sort(@model.terminal) == Enum.sort(Enum.filter(Status.all(), &Status.terminal?/1))
  end

  test "park, signal, wake, complete: the observed trace is accepted by the model",
       %{store: store, log: log, fx: fx} do
    {:ok, _} = Engine.start(store, LaneBFx.attrs("t1", fx, kinds: %{integrate: :await}), @opts)
    assert {:parked, :waiting} = Engine.attempt(store, "t1", @opts)
    {:ok, _} = Engine.signal(store, "t1", "go", :now, @opts)
    assert [{"t1", {:completed, _}}] = drain(store)

    events = RecordingStore.events(log)
    assert Enum.any?(events, &match?({:deliver, "t1", :waiting}, &1))
    assert Enum.any?(events, &match?({:transition, "t1", :completed}, &1))
    assert check(events) == :ok
    # NoDoubleEffect on real state: every effect ran once.
    assert Enum.all?(Effects.all(fx), fn {_k, n} -> n == 1 end)
  end

  test "cancel from a parked run: the observed trace is accepted by the model",
       %{store: store, log: log, fx: fx} do
    {:ok, _} = Engine.start(store, LaneBFx.attrs("t2", fx, kinds: %{integrate: :await}), @opts)
    assert {:parked, :waiting} = Engine.attempt(store, "t2", @opts)
    assert {:ok, _} = Engine.cancel(store, "t2", @opts)
    drain(store)

    events = RecordingStore.events(log)
    assert Engine.fetch(store, "t2", @opts).status == :cancelled
    assert Enum.any?(events, &match?({:transition, "t2", :cancelling}, &1))
    assert check(events) == :ok
  end

  test "corrupted traces are refused (anti-vacuity)", %{store: store, log: log, fx: fx} do
    {:ok, _} = Engine.start(store, LaneBFx.attrs("t3", fx), @opts)
    Engine.attempt(store, "t3", @opts)
    good = RecordingStore.events(log)
    assert check(good) == :ok

    assert {:violation, :terminal_absorbing, _} =
             check(good ++ [{:transition, "t3", :waiting}])

    assert {:violation, :cancel_overwritten, _} =
             check([{:transition, "t3", :cancelling}, {:transition, "t3", :completed}])

    assert {:violation, :illegal_transition, _} =
             check([{:transition, "t3", :unwinding}, {:transition, "t3", :pending}])

    assert {:violation, :claim_exclusive, _} =
             check([{:claim, "t3", "w1", :ok}, {:claim, "t3", "w2", :ok}])

    assert {:violation, :double_effect, _} =
             check([{:record, "t3", "k", 1}, {:record, "t3", "k", 2}])

    assert {:violation, :lost_wakeup, _} = check([{:deliver, "t3", :waiting}])
  end
end
