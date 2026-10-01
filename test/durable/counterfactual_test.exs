defmodule AshPPlan.Reactor.Durable.CounterfactualTest do
  @moduledoc """
  Court: `AshPPlan.Reactor.Durable.Counterfactual` replays a recorded durable run in a scratch
  store with one change applied. Real `Store.Ets`, real Reactor, real counting effects, no mocks.

  Asserts: the original ledger digest is equal before and after every replay; an identical change
  (same realization, same recorded output, empty change) yields an empty diff; a provider swap
  re-executes exactly the swapped task and shows it as a changed event plus a changed result; a
  failed run replayed with a fixed output flips failed -> completed and not-standing -> standing;
  two replays produce equal diffs and equal OCEL exports; invalid changes are typed refusals.

  Anti-vacuity mutations: dropping the copy of recorded checkpoints in `seed/5` makes the
  identical-change replay re-execute everything (empty-diff and re-executed-set assertions
  fail); making `ledger_digest/3` constant, or replaying against the original store instead of a
  scratch store, fails the untouched and effect-count assertions; dropping the dependents
  closure fails the provider-swap and outcome-flip assertions.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Realization
  alias AshPPlan.Reactor.Durable.{Clock, Counterfactual, Engine}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.{DurableFx, Effects}

  defmodule AltEffect do
    @moduledoc "Alternative provider's step: same contract, different output."
    use Reactor.Step
    @impl true
    def run(_arguments, _context, _options), do: {:ok, {:alt_commit, :b}}
  end

  defmodule AltAdapter do
    @moduledoc "Provider B for `shipment_commit`."
    @behaviour AshPPlan.Reactor.Adapter
    @impl true
    def id, do: :cf_alt
    @impl true
    def available?, do: true
    @impl true
    def ops, do: [:shipment_commit]
    @impl true
    def step(op, options),
      do:
        AshPPlan.Reactor.Adapter.resolve(
          __MODULE__,
          %{shipment_commit: {AltEffect, []}},
          op,
          options
        )
  end

  setup do
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    DurableFx.install_adapter!()
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :cf_alt, AltAdapter)
    )

    on_exit(fn -> Application.put_env(:ash_pplan, :extra_adapters, previous) end)

    effects = :"cf_effects_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: effects)
    {:ok, store} = Ets.start_link()
    {:ok, store: store, effects: effects}
  end

  defp start(store, effects, id) do
    {:ok, _} = Engine.start(store, DurableFx.attrs(id, effects: effects))
    store
  end

  defp complete(store, effects, id) do
    start(store, effects, id)
    assert {:parked, _} = Engine.attempt(store, id)
    {:ok, _} = Engine.signal(store, id, DurableFx.signal_name(), %{released: true})
    assert {:completed, _} = Engine.attempt(store, id)
    id
  end

  defp alt_binding do
    %Realization{
      capability: "Shipment.Commit",
      provider: :cf_alt,
      binding: %{adapter: :cf_alt, op: :shipment_commit},
      options: []
    }
  end

  test "identical change: untouched original, empty diff, nothing re-executed past the change",
       %{store: store, effects: effects} do
    id = complete(store, effects, "cf-same")
    before = Counterfactual.ledger_digest(store, id)
    counts = Effects.all(effects)

    same = DurableFx.bindings(effects).commit_shipment
    recorded = Map.new(Engine.steps(store, id), &{&1.label, &1.output})

    for change <- [%{}, %{provider: %{commit_shipment: same}}] do
      assert {:ok, r} = Counterfactual.replay(store, id, change: change)
      assert r.untouched?
      assert r.diff.empty?
      assert r.diff.events == %{added: [], removed: [], changed: []}
      assert r.original.status == :completed and r.counterfactual.status == :completed
      assert r.original.events != []
      assert r.original.events == r.counterfactual.events
    end

    # only the recorded output substituted unchanged: no step re-executes at all
    out = recorded |> Map.values() |> Enum.find(&match?({:commit, _}, &1))

    assert {:ok, r} =
             Counterfactual.replay(store, id, change: %{outputs: %{commit_shipment: out}})

    assert r.diff.empty?
    assert r.diff.tasks_reexecuted == []
    assert r.diff.result.changed? == false

    assert Counterfactual.ledger_digest(store, id) == before
    # the original store's effects only moved for the one re-executed commit step
    assert Effects.count(effects, :admit) == counts[:admit]
    assert Effects.count(effects, :authorize) == counts[:authorize]
  end

  test "provider swap re-executes the swapped task and shows the diff", %{
    store: store,
    effects: effects
  } do
    id = complete(store, effects, "cf-swap")
    before = Counterfactual.ledger_digest(store, id)
    commits = Effects.count(effects, :commit)

    assert {:ok, r} =
             Counterfactual.replay(store, id,
               change: %{provider: %{commit_shipment: alt_binding()}}
             )

    assert r.untouched?
    assert Counterfactual.ledger_digest(store, id) == before
    assert r.diff.tasks_reexecuted == [:commit_shipment]
    refute r.diff.empty?
    assert [_attempted, _succeeded] = r.diff.events.changed
    assert Enum.all?(r.diff.events.changed, &(&1.id =~ "commit_shipment"))
    assert r.diff.outcome.changed? == false
    assert r.diff.result.changed?

    assert {:alt_commit, :b} =
             r.counterfactual.result |> flatten() |> Enum.find(&match?({:alt_commit, _}, &1))

    assert r.counterfactual.ocel =~ "real:cf_alt"
    assert r.original.ocel =~ "real:durable_fx"
    # provider B never touched provider A's effect counter
    assert Effects.count(effects, :commit) == commits
  end

  test "failed run replayed with a fixed output flips the outcome", %{
    store: store,
    effects: effects
  } do
    id = "cf-fail"
    start(store, effects, id)
    Effects.fail_after(effects, :authorize, 0)
    assert {:failed, _} = Engine.attempt(store, id)
    assert Engine.fetch(store, id).status == :failed
    before = Counterfactual.ledger_digest(store, id)

    fixed = %{authorize_payment: {:authorize, 1}, await_human_release: %{released: true}}
    assert {:ok, r} = Counterfactual.replay(store, id, change: %{outputs: fixed})

    assert r.untouched?
    assert Counterfactual.ledger_digest(store, id) == before
    assert r.diff.outcome == %{before: :failed, after: :completed, changed?: true}
    assert r.diff.standing == %{before: :not_standing, after: :standing, changed?: true}
    assert r.diff.tasks_reexecuted == [:commit_shipment]
    assert Enum.any?(r.original.events, &(&1.activity == "task_failed"))
    refute Enum.any?(r.counterfactual.events, &(&1.activity == "task_failed"))
    assert Engine.fetch(store, id).status == :failed
  end

  test "replay is deterministic", %{store: store, effects: effects} do
    id = complete(store, effects, "cf-det")
    change = %{provider: %{commit_shipment: alt_binding()}}
    assert {:ok, a} = Counterfactual.replay(store, id, change: change)
    assert {:ok, b} = Counterfactual.replay(store, id, change: change)
    assert a.diff == b.diff
    assert a.counterfactual.ocel == b.counterfactual.ocel
    assert a.original.ocel == b.original.ocel
  end

  test "typed refusals for invalid changes", %{store: store, effects: effects} do
    id = complete(store, effects, "cf-bad")

    assert {:error, %{reason: :invalid_change, detail: {:unknown_task, [:nope]}}} =
             Counterfactual.replay(store, id, change: %{outputs: %{nope: 1}})

    assert {:error, %{reason: :invalid_change, detail: {:unknown_change, [:weather]}}} =
             Counterfactual.replay(store, id, change: %{weather: 1})

    assert {:error, %{reason: :run_not_found}} =
             Counterfactual.replay(store, "missing", change: %{})
  end

  defp flatten(term) when is_tuple(term),
    do: [term | term |> Tuple.to_list() |> Enum.flat_map(&flatten/1)]

  defp flatten(term) when is_map(term), do: term |> Map.values() |> Enum.flat_map(&flatten/1)
  defp flatten(term) when is_list(term), do: Enum.flat_map(term, &flatten/1)
  defp flatten(_), do: []
end
