defmodule AshPPlan.MirrorSim.KillDurableFx do
  @moduledoc "Self-contained parent fixture: `prep -> child` where child is a real Dispatch step."
  alias AshPPlan.Reactor.Durable.Steps
  alias AshPPlan.Realization
  alias AshPPlan.Test.DurableFx
  alias AshPPlan.Workflow.Model

  defmodule Adapter do
    @moduledoc false
    @behaviour AshPPlan.Reactor.Adapter

    @impl true
    def id, do: :kill_dispatch_fx
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

  def child_spec(_arguments, _context, child_effects),
    do: %{model: DurableFx.model(), bindings: DurableFx.bindings(child_effects)}

  def install_adapter! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :kill_dispatch_fx, Adapter)
    )

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        %{} = prev -> Application.put_env(:ash_pplan, :extra_adapters, prev)
        other -> Application.put_env(:ash_pplan, :extra_adapters, other)
      end
    end)

    :ok
  end

  def model do
    {:ok, m} =
      Model.new(
        name: "kill_dispatch_parent",
        goal: "kill_dispatch_parent_goal",
        methods: [%{id: :spine, task: :kill_dispatch_parent_goal, subtasks: [:prep, :child]}],
        tasks: [
          %{id: :prep, capability: "Order.Admit", depends_on: []},
          %{id: :child, capability: "Workflow.Dispatch", depends_on: [:prep]}
        ]
      )

    m
  end

  def attrs(id, parent_effects, child_effects) do
    bindings = %{
      prep: %Realization{
        capability: "Order.Admit",
        provider: :kill_dispatch_fx,
        binding: %{adapter: :kill_dispatch_fx, op: :order_admit},
        options: [effects: parent_effects]
      },
      child: %Realization{
        capability: "Workflow.Dispatch",
        provider: :kill_dispatch_fx,
        binding: %{adapter: :kill_dispatch_fx, op: :workflow_dispatch},
        options: [workflow: {__MODULE__, :child_spec, [child_effects]}, timeout: nil]
      }
    }

    %{
      id: id,
      model: model(),
      bindings: bindings,
      inputs: %{input: %{}},
      context: %{},
      parent: nil
    }
  end
end

defmodule AshPPlan.MirrorSim.KillDurableTest do
  @moduledoc """
  Mirror-sim kill tests for surviving mutants PD-01, DS-05, DS-06, DS-08, over the real
  `Engine`, `Store.Ets`, `Clock` and `PolicyDriver` (no doubles, no sleeping).

  Flipping assertions:
    * PD-01 (`observed in admitted` -> `true`): `observe/4` of an inadmissible successor is
      `{:error, {:outcome_outside_policy_domain, _}}`.
    * DS-05 (`classify` always `:live`): a parent re-attempted over an already-terminal child
      completes from the child row and holds no waiter.
    * DS-06 (`child_id` from fixed atom): the child run exists under
      `Key.child_id(parent, step_name)` and nowhere else.
    * DS-08 (`advance` leaves time unchanged): `Clock.advance/1` moves `Clock.now/0` by exactly
      the requested milliseconds.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.FOND
  alias AshPPlan.MirrorSim.KillDurableFx, as: Fx
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Key, PolicyDriver, Testing}
  alias AshPPlan.Reactor.Durable.Steps.Dispatch
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.{DurableFx, Effects}

  @start ~U[2026-01-01 00:00:00Z]

  setup do
    Clock.use_test_clock(@start)
    on_exit(&Clock.reset/0)
    DurableFx.install_adapter!()
    Fx.install_adapter!()
    {:ok, store} = Ets.start_link([])
    n = System.unique_integer([:positive])
    {:ok, pe} = Effects.start_link(name: :"kill_durable_parent_#{n}")
    {:ok, ce} = Effects.start_link(name: :"kill_durable_child_#{n}")
    %{store: store, pe: pe, ce: ce}
  end

  defp child_step, do: AshPPlan.Workflow.Project.Reactor.step_iri(Fx.model(), :child)

  test "PD-01: observe refuses a successor the domain does not admit" do
    {:ok, d} =
      FOND.new(
        %{
          start: %{charge_backup: [:paid, :declined]},
          paid: %{},
          declined: %{}
        },
        [:paid, :declined]
      )

    {:ok, driver} = PolicyDriver.new(d, :start)

    assert {:ok, :paid} = PolicyDriver.observe(driver, :start, :charge_backup, :paid)

    assert {:error, {:outcome_outside_policy_domain, %{observed: :refunded, admitted: admitted}}} =
             PolicyDriver.observe(driver, :start, :charge_backup, :refunded)

    assert Enum.sort(admitted) == [:declined, :paid]
  end

  test "DS-05: a terminal child answers the parent from its row, leaving no waiter",
       %{store: s, pe: pe, ce: ce} do
    {:ok, _} = Engine.start(s, Fx.attrs("kd5", pe, ce))
    Testing.drain(s)
    cid = Key.child_id("kd5", child_step())

    {:ok, _} = Testing.signal(s, cid, DurableFx.signal_name(), :released)
    Engine.attempt(s, cid)
    assert Testing.status(s, cid) == :completed

    # Lose the child's completion report before the parent reads it.
    signal = Dispatch.signal_name(child_step())
    pending = Ets.pending_signal(s, "kd5", signal)
    assert pending
    {:ok, _} = Ets.consume_signal(s, pending.id, Clock.now())

    Engine.attempt(s, "kd5")

    assert Testing.status(s, "kd5") == :completed
    assert Engine.fetch(s, "kd5").result == Engine.fetch(s, cid).result
    assert Ets.get_waiter(s, "kd5", signal) == nil
  end

  test "DS-06: the child run lives under the id derived from parent and step name",
       %{store: s, pe: pe, ce: ce} do
    {:ok, _} = Engine.start(s, Fx.attrs("kd6", pe, ce))
    Testing.drain(s)

    cid = Key.child_id("kd6", child_step())
    refute cid == Key.child_id("kd6", :fixed)

    assert %{parent_id: "kd6"} = Engine.fetch(s, cid)
    assert Engine.fetch(s, Key.child_id("kd6", :fixed)) == nil
    assert s |> Ets.list_runs() |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort(["kd6", cid])
  end

  test "DS-08: Clock.advance moves the test clock by exactly the requested milliseconds" do
    assert Clock.now() == @start
    returned = Clock.advance(1_500)
    expected = DateTime.add(@start, 1_500, :millisecond)

    assert returned == expected
    assert Clock.now() == expected
    assert Clock.advance(500) == DateTime.add(expected, 500, :millisecond)
    assert Clock.now() == DateTime.add(@start, 2_000, :millisecond)
  end
end
