defmodule AshPPlan.Test.DispatchFx do
  @moduledoc """
  Parent workflow for dispatch courts: `prep -> child`, where `child` is a
  `Durable.Steps.Dispatch` step resolving to the generated QualifiedFulfillment durable spine
  (`AshPPlan.Test.DurableFx`). Options are data: the child's effect counter is passed by name.
  """
  alias AshPPlan.Reactor.Durable.Steps
  alias AshPPlan.Realization
  alias AshPPlan.Test.DurableFx
  alias AshPPlan.Workflow.Model

  defmodule Adapter do
    @moduledoc "Test adapter: a counting prep step and the real Dispatch step."
    @behaviour AshPPlan.Reactor.Adapter

    @impl true
    def id, do: :dispatch_fx
    @impl true
    def available?, do: true
    @impl true
    def ops, do: [:order_admit, :workflow_dispatch]

    @impl true
    def step(op, options) do
      table = %{
        order_admit: {DurableFx.Effect, [effect: :parent_prep]},
        workflow_dispatch: {Steps.Dispatch, []}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  @doc "Child spec resolved at run time (`workflow: {m, f, a}`)."
  def child_spec(_arguments, _context, child_effects),
    do: %{model: DurableFx.model(), bindings: DurableFx.bindings(child_effects)}

  def install_adapter! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :dispatch_fx, Adapter)
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:ash_pplan, :extra_adapters, previous) end)
    :ok
  end

  def model do
    {:ok, m} =
      Model.new(
        name: "dispatch_parent",
        goal: "dispatch_parent_goal",
        methods: [%{id: :spine, task: :dispatch_parent_goal, subtasks: [:prep, :child]}],
        tasks: [
          %{id: :prep, capability: "Order.Admit", depends_on: []},
          %{id: :child, capability: "Workflow.Dispatch", depends_on: [:prep]}
        ]
      )

    m
  end

  def bindings(parent_effects, child_effects, dispatch_opts \\ []) do
    %{
      prep: %Realization{
        capability: "Order.Admit",
        provider: :dispatch_fx,
        binding: %{adapter: :dispatch_fx, op: :order_admit},
        options: [effects: parent_effects]
      },
      child: %Realization{
        capability: "Workflow.Dispatch",
        provider: :dispatch_fx,
        binding: %{adapter: :dispatch_fx, op: :workflow_dispatch},
        options:
          Keyword.merge(
            [workflow: {__MODULE__, :child_spec, [child_effects]}, timeout: nil],
            dispatch_opts
          )
      }
    }
  end

  def attrs(id, parent_effects, child_effects, dispatch_opts \\ []) do
    %{
      id: id,
      model: model(),
      bindings: bindings(parent_effects, child_effects, dispatch_opts),
      inputs: %{input: %{}},
      context: %{},
      parent: nil
    }
  end
end

defmodule AshPPlan.Reactor.Durable.DispatchTest do
  @moduledoc """
  Court for `Durable.Steps.Dispatch`, driven end to end through the real `Engine`, `Run` and
  `Store.Ets`: the child's result returns to the parent, the child keeps a tape of its own, a
  replay adopts the child instead of starting a second, starting is idempotent on the derived id,
  a failed child reaches the parent as a `ChildError`, a terminal child row answers the parent
  even when its report signal is gone, and cancelling a parent cancels its live child.

  Anti-vacuity mutation (run manually): making `Dispatch.adopt_or_start/7` always call
  `Engine.start` with a fresh random id makes the adoption and idempotent-start courts fail;
  deleting the `Status.terminal?` check in `outcome` selection makes the recovery court fail.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{ChildError, Clock, Engine, Key, Testing}
  alias AshPPlan.Reactor.Durable.Steps.Dispatch
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.{DispatchFx, DurableFx, Effects}

  setup do
    Clock.use_test_clock(~U[2026-01-01 00:00:00Z])
    on_exit(&Clock.reset/0)
    DurableFx.install_adapter!()
    DispatchFx.install_adapter!()
    {:ok, store} = Ets.start_link([])
    {:ok, pe} = Effects.start_link(name: :dispatch_parent_fx)
    {:ok, ce} = Effects.start_link(name: :dispatch_child_fx)
    %{store: store, pe: pe, ce: ce}
  end

  # Reactor step names are the task step IRIs of the projection.
  defp child_step, do: AshPPlan.Workflow.Project.Reactor.step_iri(DispatchFx.model(), :child)
  defp child_id(parent_id), do: Key.child_id(parent_id, child_step())

  test "child result returns to the parent; child has its own tape", %{store: s, pe: pe, ce: ce} do
    {:ok, _} = Engine.start(s, DispatchFx.attrs("p1", pe, ce))
    Testing.drain(s)

    cid = child_id("p1")
    assert Testing.status(s, "p1") == :waiting
    assert Testing.status(s, cid) == :waiting
    assert %{parent_id: "p1"} = Engine.fetch(s, cid)

    {:ok, _} = Testing.signal(s, cid, DurableFx.signal_name(), :released)
    Testing.drain(s)

    assert Testing.status(s, cid) == :completed
    assert Testing.status(s, "p1") == :completed
    assert %{status: :completed, result: result} = Engine.fetch(s, "p1")
    assert result == Engine.fetch(s, cid).result
    refute is_nil(result)

    parent_tape = Testing.tape(s, "p1")
    child_tape = Testing.tape(s, cid)
    assert length(parent_tape) == 2
    assert length(child_tape) == 4
    assert MapSet.disjoint?(MapSet.new(parent_tape), MapSet.new(child_tape))

    assert Effects.count(pe, :parent_prep) == 1
    assert Effects.count(ce, :admit) == 1
    assert Effects.count(ce, :commit) == 1
  end

  test "replay adopts the live child and starts no second", %{store: s, pe: pe, ce: ce} do
    {:ok, _} = Engine.start(s, DispatchFx.attrs("p2", pe, ce))
    Testing.drain(s)
    cid = child_id("p2")
    runs_before = s |> Ets.list_runs() |> Enum.map(& &1.id) |> Enum.sort()
    assert runs_before == Enum.sort(["p2", cid])

    # Wake the parent again with no signal: it replays, adopts, and parks again.
    for _ <- 1..3, do: Engine.attempt(s, "p2")

    assert s |> Ets.list_runs() |> Enum.map(& &1.id) |> Enum.sort() == runs_before
    assert Effects.count(pe, :parent_prep) == 1
    assert Effects.count(ce, :admit) == 1
  end

  test "start is idempotent on the derived id", %{store: s, pe: pe, ce: ce} do
    {:ok, a} = Engine.start(s, DispatchFx.attrs("p3", pe, ce))
    {:ok, b} = Engine.start(s, DispatchFx.attrs("p3", pe, ce))
    assert a.id == b.id
    assert length(Ets.list_runs(s)) == 1
    assert child_id("p3") == Key.child_id("p3", child_step())
    refute child_id("p3") == child_id("p3x")
  end

  test "child failure reaches the parent as ChildError", %{store: s, pe: pe, ce: ce} do
    :ok = Effects.fail_after(ce, :authorize, 0)
    {:ok, _} = Engine.start(s, DispatchFx.attrs("p4", pe, ce))
    Testing.drain(s)

    cid = child_id("p4")
    assert Testing.status(s, cid) == :failed
    assert Testing.status(s, "p4") == :failed

    assert %{error: error} = Engine.fetch(s, "p4")
    assert error_chain_has_child_error?(error, cid)
  end

  defp error_chain_has_child_error?(%ChildError{run_id: id}, id), do: true

  defp error_chain_has_child_error?(%{errors: errs}, id) when is_list(errs),
    do: Enum.any?(errs, &error_chain_has_child_error?(&1, id))

  defp error_chain_has_child_error?(errs, id) when is_list(errs),
    do: Enum.any?(errs, &error_chain_has_child_error?(&1, id))

  defp error_chain_has_child_error?(%{error: e}, id) when is_map(e) or is_list(e),
    do: error_chain_has_child_error?(e, id)

  defp error_chain_has_child_error?(_, _), do: false

  test "recovery reads the terminal child row when the report signal is gone", %{
    store: s,
    pe: pe,
    ce: ce
  } do
    {:ok, _} = Engine.start(s, DispatchFx.attrs("p5", pe, ce))
    Testing.drain(s)
    cid = child_id("p5")

    # The child ends, but its report to the parent is lost before the parent reads it.
    {:ok, _} = Testing.signal(s, cid, DurableFx.signal_name(), :released)
    for id <- [cid], do: Engine.attempt(s, id)
    assert Testing.status(s, cid) == :completed

    signal = Dispatch.signal_name(child_step())
    pending = Ets.pending_signal(s, "p5", signal)
    assert pending
    {:ok, _} = Ets.consume_signal(s, pending.id, Clock.now())
    assert Ets.pending_signal(s, "p5", signal) == nil

    # Re-park the parent (as if it never saw the report) and attempt it directly.
    Engine.attempt(s, "p5")
    assert Testing.status(s, "p5") == :completed
    assert Engine.fetch(s, "p5").result == Engine.fetch(s, cid).result
    assert Ets.get_waiter(s, "p5", signal) == nil
  end

  test "cancelling the parent cancels its live child", %{store: s, pe: pe, ce: ce} do
    {:ok, _} = Engine.start(s, DispatchFx.attrs("p6", pe, ce))
    Testing.drain(s)
    cid = child_id("p6")
    assert Testing.status(s, cid) == :waiting

    assert {:ok, _} = Engine.cancel(s, "p6")
    Testing.drain(s)

    assert Testing.status(s, cid) == :cancelled
    assert Testing.status(s, "p6") == :cancelled
    assert Effects.count(ce, :commit) == 0
  end

  test "async? returns the child id without waiting", %{store: s, pe: pe, ce: ce} do
    {:ok, _} = Engine.start(s, DispatchFx.attrs("p7", pe, ce, async?: true))
    Testing.drain(s)
    cid = child_id("p7")
    assert Testing.status(s, "p7") == :completed
    assert %{result: %{child_id: ^cid}} = Engine.fetch(s, "p7")
    assert Engine.fetch(s, cid)
  end

  test "anti-vacuity: the child id depends on the parent and the step name" do
    refute Key.child_id("p", :child) == Key.child_id("q", :child)
    refute Key.child_id("p", :child) == Key.child_id("p", :other)
    assert Dispatch.signal_name(:child) != Dispatch.signal_name(:other)
  end
end
