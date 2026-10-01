defmodule AshPPlan.Reactor.Durable.CancelProbeStore do
  @moduledoc """
  A real `AshPPlan.Reactor.Durable.Store` delegating every callback to the real ETS store that,
  once armed, fires a genuine `Engine.cancel` against the same table at the first `record`
  boundary — i.e. in the middle of a `Migration.apply` rekey. Hand-written implementation of the
  store interface over real shared state, not a mock: nothing stubbed, nothing call-counted.
  """
  @behaviour AshPPlan.Reactor.Durable.Store

  alias AshPPlan.Reactor.Durable.{Engine, Store.Ets}

  @plan __MODULE__.Plan

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: Ets.start_link(opts)

  def start_plan, do: Agent.start_link(fn -> %{armed: false} end, name: @plan)

  def arm(run_id, ets),
    do: Agent.update(@plan, fn _ -> %{armed: true, run_id: run_id, ets: ets, result: nil} end)

  def disarm,
    do: if(Process.whereis(@plan), do: Agent.update(@plan, fn p -> %{p | armed: false} end))

  def result, do: Agent.get(@plan, & &1.result)

  # Fires once, at the first record boundary after arming.
  defp point(run_id) do
    fire? =
      Agent.get_and_update(@plan, fn
        %{armed: true} = p -> {true, %{p | armed: false, result: :fired}}
        p -> {false, p}
      end)

    if fire? do
      ets = Agent.get(@plan, & &1.ets)
      result = Engine.cancel(ets, run_id)
      Agent.update(@plan, &%{&1 | result: result})
    end

    :ok
  end

  @impl true
  def start_run(s, a), do: Ets.start_run(s, a)
  @impl true
  def get_run(s, id), do: Ets.get_run(s, id)
  @impl true
  def list_runs(s), do: Ets.list_runs(s)
  @impl true
  def transition(s, id, from, to, attrs), do: Ets.transition(s, id, from, to, attrs)
  @impl true
  def claim(s, id, claimer, lease, now), do: Ets.claim(s, id, claimer, lease, now)
  @impl true
  def release_claim(s, id, claimer), do: Ets.release_claim(s, id, claimer)
  @impl true
  def checkpoints(s, id), do: Ets.checkpoints(s, id)
  @impl true
  def standing(s, id), do: Ets.standing(s, id)

  @impl true
  def record(s, id, key, label, output, meta) do
    result = Ets.record(s, id, key, label, output, meta)
    point(id)
    result
  end

  @impl true
  def claim_undo(s, id, key, now), do: Ets.claim_undo(s, id, key, now)
  @impl true
  def release_undo(s, id, key), do: Ets.release_undo(s, id, key)
  @impl true
  def deliver_signal(s, id, name, payload), do: Ets.deliver_signal(s, id, name, payload)
  @impl true
  def pending_signal(s, id, name), do: Ets.pending_signal(s, id, name)
  @impl true
  def consume_signal(s, sid, now), do: Ets.consume_signal(s, sid, now)

  @impl true
  def park(s, id, name, kind, deadline, opts), do: Ets.park(s, id, name, kind, deadline, opts)
  @impl true
  def get_waiter(s, id, name), do: Ets.get_waiter(s, id, name)
  @impl true
  def waiters(s, id), do: Ets.waiters(s, id)
  @impl true
  def release(s, id, name), do: Ets.release(s, id, name)
  @impl true
  def release_all(s, id), do: Ets.release_all(s, id)
  @impl true
  def signals(s, id), do: Ets.signals(s, id)
end

defmodule AshPPlan.Reactor.Durable.MigrationCancelRaceTest do
  @moduledoc """
  Court for audit defect (1): `Migration.apply` vs a concurrent `Engine.cancel`.

  `cancel` is refused while a migration claim is held, so a cancel landing mid-apply (injected at
  the real `record` boundary during the rekey) returns a typed `{:claim_held, id}` error and the
  run ends FULLY migrated; a cancel refused while the claim is held writes nothing; a cancel
  outside the claim window still works.
  """
  use ExUnit.Case, async: false

  Code.require_file("lane_b_fixture.exs", __DIR__)

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Migration}
  alias AshPPlan.Reactor.Durable.CancelProbeStore
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Workflow.Model

  setup do
    LaneBFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    name = :"mcr_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = AshPPlan.Test.Effects.start_link(name: name)
    {:ok, store} = Ets.start_link()
    {:ok, _} = CancelProbeStore.start_plan()
    CancelProbeStore.disarm()
    {:ok, store: store, fx: name}
  end

  defp renamed_model do
    old = LaneBFx.model(:linear)

    tasks =
      Enum.map(old.tasks, fn t ->
        t = Map.from_struct(t)
        %{t | id: rename(t.id), depends_on: Enum.map(t.depends_on, &rename/1)}
      end)

    {:ok, m} = Model.new(name: old.name, goal: old.goal, tasks: tasks)
    m
  end

  defp rename(:observe), do: :observe_frontier
  defp rename(id), do: id

  defp content(store, id),
    do:
      store
      |> Engine.fetch(id)
      |> Map.take([:model, :bindings, :context, :status, :inputs, :result])

  defp parked(store, fx, id) do
    {:ok, _} = Engine.start(store, LaneBFx.attrs(id, fx, kinds: %{integrate: :await}))
    assert {:parked, :waiting} = Engine.attempt(store, id)
  end

  test "cancel injected mid-apply (during the rekey) is refused and the run is fully migrated", %{
    fx: fx
  } do
    {:ok, store} = CancelProbeStore.start_link()
    parked(store, fx, "mcr1")

    CancelProbeStore.arm("mcr1", store)

    old = LaneBFx.model(:linear)

    assert {:ok, plan} =
             Migration.plan(old, renamed_model(), renames: %{observe: :observe_frontier})

    assert {:ok, %{status: :migrated}} =
             Migration.apply(store, "mcr1", plan, store_module: CancelProbeStore)

    assert {:error, {:claim_held, "mcr1"}} = CancelProbeStore.result()

    # Fully migrated: the model moved and no checkpoint stands under the OLD key.
    rec = Engine.fetch(store, "mcr1")
    # Only a RENAMED step's old key must be gone; unchanged steps keep standing as-is.
    old_keys =
      for %{old_key: k, new_key: nk} <- plan.steps, k != nk, into: MapSet.new(), do: k

    standing_old =
      store
      |> Ets.checkpoints("mcr1")
      |> Map.values()
      |> Enum.filter(&is_nil(&1.undone_at))
      |> Enum.map(& &1.step_key)
      |> MapSet.new()
      |> MapSet.intersection(old_keys)

    assert MapSet.size(standing_old) == 0
    assert rec.model.name == renamed_model().name
  end

  test "cancel refused while a migration claim is held writes nothing", %{store: store, fx: fx} do
    parked(store, fx, "mcr1")

    # The refused cancel may not touch the run's CONTENT (claim bookkeeping aside).
    before = content(store, "mcr1")

    {:ok, _} = Ets.claim(store, "mcr1", "migration-court-999", 30_000, Clock.now())

    assert {:error, {:claim_held, "mcr1"}} = Engine.cancel(store, "mcr1")

    assert content(store, "mcr1") == before
  end

  test "cancel outside the claim window still works", %{store: store, fx: fx} do
    parked(store, fx, "mcr1")
    assert {:ok, %{status: :cancelling}} = Engine.cancel(store, "mcr1")
  end
end
