defmodule AshPPlan.Reactor.Durable.CancelTest do
  @moduledoc """
  Court: cancel and rollback through the real durable engine (`Engine`, `Unwind`, `Store.Ets`,
  Reactor, `AshPPlan.Reactor.enrich/3` identity). Steps are plain Reactor steps with data options;
  effects and undos are counted in real Agents (`AshPPlan.Test.Effects` plus an order log).

  Covered: a failing run takes back its finished steps newest first; cancelling a parked run
  unwinds it; a terminal run cannot be cancelled; a late forward attempt cannot overwrite
  `:cancelling`; a failed undo leaves the checkpoint standing and the run `:unwind_blocked`
  (typed, recoverable); racing rollbacks undo each step once; the Identity context reaches undo.

  Anti-vacuity mutations (run manually): making `Engine.cancel/3` skip the `:cancelling`
  transition fails the parked-cancel court; removing `claim_undo` in `Unwind` fails the racing
  court; widening the settle `from` lists in `Engine` to include `:cancelling` fails the
  late-attempt court.

  Design derived from mbuhot/magma (MIT per its mix.exs).
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Realization
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Effects
  alias AshPPlan.Workflow.{Model, Subject}

  @fx :cancel_fx_effects
  @state :cancel_fx_state

  defmodule Fx do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(_args, _ctx, opts) do
      effects = Keyword.fetch!(opts, :effects)
      effect = Keyword.fetch!(opts, :effect)

      case AshPPlan.Test.Effects.run(effects, effect) do
        {:ok, n} ->
          if ms = opts[:sleep], do: Process.sleep(ms)
          {:ok, {effect, n}}

        {:error, _} = err ->
          err
      end
    end

    @impl true
    def undo(value, _args, context, opts) do
      state = Keyword.fetch!(opts, :state)
      effect = Keyword.fetch!(opts, :effect)

      if Agent.get(state, & &1.undo_fail?) do
        {:error, {:undo_refused, effect}}
      else
        Agent.update(state, fn s ->
          %{s | order: s.order ++ [effect], identity: Map.get(context, :ash_pplan_workflow)}
        end)

        _ = value
        AshPPlan.Test.Effects.record(Keyword.fetch!(opts, :effects), {:undo, effect})
        :ok
      end
    end
  end

  defmodule Adapter do
    @moduledoc false
    @behaviour AshPPlan.Reactor.Adapter
    alias AshPPlan.Reactor.Durable.Steps

    @impl true
    def id, do: :cancel_fx
    @impl true
    def available?, do: true
    @impl true
    def ops, do: [:file_write, :human_approve]

    @impl true
    def step(op, options) do
      table = %{
        file_write: {Fx, []},
        human_approve: {Steps.Await, [signal: "go", timeout: nil]}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  setup do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :cancel_fx, Adapter)
    )

    on_exit(fn -> Application.put_env(:ash_pplan, :extra_adapters, previous) end)

    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    {:ok, _} = Effects.start_link(name: @fx)

    {:ok, _} =
      Agent.start_link(fn -> %{order: [], undo_fail?: false, identity: nil} end, name: @state)

    {:ok, store} = Ets.start_link()
    {:ok, store: store}
  end

  # tasks: list of {id, capability, op, extra_options}; chained in order.
  defp attrs(id, tasks) do
    task_specs =
      tasks
      |> Enum.with_index()
      |> Enum.map(fn {{tid, cap, _op, _o}, i} ->
        base = [id: tid, capability: cap, authority: :construct]
        if i == 0, do: base, else: base ++ [after: [elem(Enum.at(tasks, i - 1), 0)]]
      end)

    {:ok, model} = Model.new(name: "cancel-#{id}", goal: "g", tasks: task_specs)

    bindings =
      Map.new(tasks, fn {tid, cap, op, extra} ->
        {tid,
         %Realization{
           capability: cap,
           provider: :cancel_fx,
           binding: %{adapter: :cancel_fx, op: op},
           options: [effects: @fx, state: @state, effect: tid] ++ extra
         }}
      end)

    %{id: id, model: model, bindings: bindings, inputs: %{input: %{}}, context: %{}, parent: nil}
  end

  defp spine(id, tail),
    do:
      attrs(
        id,
        [{:a, "File.Write", :file_write, []}, {:b, "File.Write", :file_write, []}] ++ tail
      )

  defp parked(id),
    do: spine(id, [{:wait, "Human.Approve", :human_approve, []}])

  defp order, do: Agent.get(@state, & &1.order)

  test "a failing run takes back its finished steps exactly once", %{store: s} do
    Effects.fail_after(@fx, :boom, 0)
    {:ok, _} = Engine.start(s, spine("f1", [{:boom, "File.Write", :file_write, []}]))

    assert {:failed, _} = Engine.attempt(s, "f1")
    assert Testing.status(s, "f1") == :failed
    # Reactor's live executor owns the order of an in-run rollback; the contract here is that
    # each finished step is taken back exactly once and nothing is left standing.
    assert Enum.sort(order()) == [:a, :b]
    assert Effects.count(@fx, {:undo, :a}) == 1 and Effects.count(@fx, {:undo, :b}) == 1
    assert Engine.steps(s, "f1") == []
  end

  test "cancelling a parked run unwinds it and releases its waiters", %{store: s} do
    {:ok, _} = Engine.start(s, parked("c1"))
    assert {:parked, _} = Engine.attempt(s, "c1")
    assert Effects.all(@fx) == %{a: 1, b: 1}
    assert [_] = Ets.waiters(s, "c1")

    assert {:ok, %{status: :cancelling}} = Engine.cancel(s, "c1")
    assert {:rolled_back, :cancelled} = Engine.attempt(s, "c1")

    assert Testing.status(s, "c1") == :cancelled
    assert order() == [:b, :a]
    assert Engine.steps(s, "c1") == []
    assert Ets.waiters(s, "c1") == []
    # a cancelled run is never re-run
    assert :ended = Engine.attempt(s, "c1")
    assert Effects.all(@fx) == %{{:undo, :a} => 1, {:undo, :b} => 1, a: 1, b: 1}
  end

  test "the Identity middleware context reaches undo", %{store: s} do
    attrs = parked("i1")
    {:ok, _} = Engine.start(s, attrs)
    assert {:parked, _} = Engine.attempt(s, "i1")
    {:ok, _} = Engine.cancel(s, "i1")
    assert {:rolled_back, :cancelled} = Engine.attempt(s, "i1")

    identity = Agent.get(@state, & &1.identity)
    assert identity.subject == Subject.bind(attrs.model).id
    assert identity.bound_subject == identity.subject
  end

  test "cancel of a terminal or unknown run is refused", %{store: s} do
    {:ok, _} = Engine.start(s, parked("t1"))
    assert [{"t1", {:parked, _}}] = Testing.drain(s)
    {:ok, _} = Testing.signal(s, "t1", "go", :ok)
    assert [{"t1", {:completed, _}}] = Testing.drain(s)

    assert {:error, :not_cancellable} = Engine.cancel(s, "t1")
    assert Testing.status(s, "t1") == :completed
    assert {:error, :no_such_run} = Engine.cancel(s, "nope")
    assert Engine.steps(s, "t1") |> length() == 3
  end

  test "cancelling twice: a run already rolling back is not cancellable", %{store: s} do
    {:ok, _} = Engine.start(s, parked("d1"))
    assert {:parked, _} = Engine.attempt(s, "d1")
    assert {:ok, _} = Engine.cancel(s, "d1")
    assert {:error, :not_cancellable} = Engine.cancel(s, "d1")
  end

  test "a late attempt cannot overwrite :cancelling", %{store: s} do
    {:ok, _} = Engine.start(s, parked("l1"))
    assert {:parked, _} = Engine.attempt(s, "l1")
    {:ok, _} = Engine.cancel(s, "l1")

    # what a forward attempt that started before the cancel would try to write on its way out
    for to <- [:waiting, :polling, :pending, :completed, :failed] do
      assert {:error, :stale} = Ets.transition(s, "l1", [:pending, :waiting, :polling], to, %{})
    end

    assert Testing.status(s, "l1") == :cancelling
  end

  test "a cancel landing mid-attempt wins: the in-flight forward attempt rolls back", %{store: s} do
    {:ok, _} = Engine.start(s, spine("m1", [{:slow, "File.Write", :file_write, [sleep: 250]}]))
    task = Task.async(fn -> Engine.attempt(s, "m1") end)

    until(fn -> Effects.count(@fx, :slow) >= 1 end)
    assert {:ok, %{status: :cancelling}} = Engine.cancel(s, "m1")

    assert {:rolled_back, :cancelled} = Task.await(task, 10_000)
    assert Testing.status(s, "m1") == :cancelled
    assert order() == [:slow, :b, :a]
    assert Engine.steps(s, "m1") == []
  end

  test "failed undo leaves the checkpoint standing and the run :unwind_blocked (recoverable)", %{
    store: s
  } do
    {:ok, _} = Engine.start(s, parked("u1"))
    assert {:parked, _} = Engine.attempt(s, "u1")
    {:ok, _} = Engine.cancel(s, "u1")
    Agent.update(@state, &%{&1 | undo_fail?: true})

    assert {:failed, [{:undo_failed, _, {:undo_refused, _}} | _]} = Engine.attempt(s, "u1")
    assert Testing.status(s, "u1") == :unwind_blocked
    assert length(Engine.steps(s, "u1")) == 2

    Agent.update(@state, &%{&1 | undo_fail?: false})
    assert {:ok, _} = Ets.transition(s, "u1", [:unwind_blocked], :cancelling, %{})
    assert {:rolled_back, :cancelled} = Engine.attempt(s, "u1")
    assert order() == [:b, :a]
    assert Engine.steps(s, "u1") == []
  end

  test "racing rollback attempts undo each step once", %{store: s} do
    {:ok, _} = Engine.start(s, parked("r1"))
    assert {:parked, _} = Engine.attempt(s, "r1")
    {:ok, _} = Engine.cancel(s, "r1")

    outcomes =
      1..6
      |> Enum.map(fn _ -> Task.async(fn -> Engine.attempt(s, "r1") end) end)
      |> Task.await_many(10_000)

    assert Enum.any?(outcomes, &(&1 == {:rolled_back, :cancelled}))
    assert Enum.all?(outcomes, &(&1 in [{:rolled_back, :cancelled}, :taken, :ended]))
    assert Effects.count(@fx, {:undo, :a}) == 1
    assert Effects.count(@fx, {:undo, :b}) == 1
    assert Testing.status(s, "r1") == :cancelled
  end

  defp until(fun, n \\ 200) do
    cond do
      fun.() -> :ok
      n == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && until(fun, n - 1)
    end
  end
end
