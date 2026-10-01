defmodule AshPPlan.Reactor.Durable.AuditRaceMigrationCancelTest do
  @moduledoc """
  Lane a0 adversarial race court: `Migration.apply/4` racing `Engine.cancel/3`.

  `Engine.cancel/3` is not claim-gated, so a run held by a migration can be moved to
  `:cancelling` mid-apply. The migration's final status transition (`switch/6`) is then stale,
  the migration reports `{:error, :transition_failed}` — but its checkpoint rewrites are already
  committed, with no ledger entry. Probed deterministically through a store wrapper that gates
  the migration's first `record/6` (the rekey write).

  Anti-vacuity mutation: make `Engine.cancel/3` check `claimed_by` before transitioning (or make
  `switch/6` roll the rekeys back on a stale transition) and this court fails to observe a
  written-but-unreported migration.
  """

  use ExUnit.Case, async: false

  Code.require_file("lane_b_fixture.exs", __DIR__)

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Migration}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Workflow.Model

  # A Store that delegates everything to `Store.Ets` but holds the migration at its first
  # checkpoint write, so the test can land the cancel inside the apply window for sure.
  defmodule GateStore do
    @moduledoc false
    @behaviour AshPPlan.Reactor.Durable.Store
    alias AshPPlan.Reactor.Durable.Store.Ets

    @gate_key {__MODULE__, :gate}

    def set_gate(pid, ref), do: :persistent_term.put(@gate_key, {pid, ref})
    def clear_gate, do: :persistent_term.erase(@gate_key)

    defmacro __using__(_), do: :ok

    @impl true
    def record(s, id, key, label, output, meta) do
      case :persistent_term.get(@gate_key, nil) do
        {test, ref} ->
          send(test, {:gate_hit, ref})

          receive do
            {:go, ^ref} -> :ok
          after
            5_000 -> :ok
          end

        nil ->
          :ok
      end

      Ets.record(s, id, key, label, output, meta)
    end

    for {f, a} <- [
          start_run: 2,
          get_run: 2,
          list_runs: 1,
          transition: 5,
          claim: 5,
          release_claim: 3,
          checkpoints: 2,
          standing: 2,
          claim_undo: 4,
          release_undo: 3,
          deliver_signal: 4,
          pending_signal: 3,
          consume_signal: 3,
          park: 6,
          get_waiter: 3,
          waiters: 2,
          release: 3,
          release_all: 2,
          signals: 2
        ] do
      args = Macro.generate_arguments(a, __MODULE__)

      @impl true
      def unquote(f)(unquote_splicing(args)) do
        Ets.unquote(f)(unquote_splicing(args))
      end
    end
  end

  setup do
    LaneBFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    GateStore.clear_gate()

    {:ok, fx} = AshPPlan.Test.Effects.start_link(name: :"race_fx_#{System.unique_integer()}")
    {:ok, store} = Ets.start_link()
    {:ok, store: store, fx: fx}
  end

  # Parked run at :waiting with observe/select/execute standing (integrate awaits a signal).
  defp parked(store, fx, id) do
    {:ok, _} = Engine.start(store, LaneBFx.attrs(id, fx, kinds: %{integrate: :await}))
    assert {:parked, :waiting} = Engine.attempt(store, id)
    assert %{status: :waiting, claimed_by: nil} = Ets.get_run(store, id)
    id
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

  test "cancel mid-apply leaves a written migration with no ledger entry", %{
    store: store,
    fx: fx
  } do
    id = parked(store, fx, "race-mig-1")
    old = LaneBFx.model(:linear)

    assert {:ok, plan} =
             Migration.plan(old, renamed_model(), renames: %{observe: :observe_frontier})

    ref = make_ref()
    GateStore.set_gate(self(), ref)

    task =
      Task.async(fn -> Migration.apply(store, id, plan, store_module: GateStore) end)

    assert_receive {:gate_hit, ^ref}, 5_000

    # Cancel lands while the migration holds the claim: cancel is not claim-gated.
    assert {:ok, cancelled} = Engine.cancel(store, id)
    assert cancelled.status == :cancelling

    send(task.pid, {:go, ref})
    result = Task.await(task, 10_000)

    # The migration's commit transition is stale...
    assert {:error, %{reason: :transition_failed}} = result

    record = Ets.get_run(store, id)

    # ...but its writes stand: the new-key checkpoint exists and the old one is retired.
    assert {:ok, plan} =
             Migration.plan(old, renamed_model(), renames: %{observe: :observe_frontier})

    step = Enum.find(plan.steps, &(&1.old_task == :observe))

    cps = Ets.checkpoints(store, id)
    assert Map.has_key?(cps, step.new_key)
    assert cps[step.old_key].undone_at != nil

    # ...and nothing was written to the migration ledger the error-reporting promised.
    assert record.context[:migrations] == nil,
           "migration wrote rekeys, reported failure, and left no ledger entry: " <>
             "apply/4 is not atomic (lib/ash_pplan/reactor/durable/migration.ex switch/6)"
  end
end
