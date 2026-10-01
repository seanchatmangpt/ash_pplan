defmodule AshPPlan.Reactor.Durable.ExtraCompositeTest do
  @moduledoc """
  Court (magma-derived): composite handling in the durable engine.

  `map` and `switch` inline their children into the outer plan, so each child checkpoints
  individually, a replay re-runs no recorded child, a switch keeps the branch it took, and step
  names are stable across attempts (a rebuilt reactor replays against the same keys). Composites
  that run a private reactor (`group`) refuse a durable wait step through the Verifier, before
  anything runs.

  Real `Store.Ets` and real Reactor; effects count into a named `Effects` agent.
  Anti-vacuity mutation (run manually): make `Run.decorate_step/2` leave `map`-returned children
  undecorated -> the per-element tape/replay tests fail; make `Verifier.check/2` ignore nesting ->
  the group refusal test fails.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Clock, Key, Run, Verifier}
  alias AshPPlan.Reactor.Durable.Steps.Await
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Effects

  defmodule Charge do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(%{id: id, fx: fx}, _context, _opts) do
      Effects.record(fx, {:charge, id})
      {:ok, {:charged, id}}
    end
  end

  defmodule Branch do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(%{amount: amount, fx: fx}, _context, opts) do
      Effects.record(fx, Keyword.fetch!(opts, :tag))
      {:ok, {Keyword.fetch!(opts, :tag), amount}}
    end
  end

  setup do
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    fx = :"fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)
    {:ok, store} = Ets.start_link()
    {:ok, store: store, fx: fx}
  end

  defmodule Mapped do
    @moduledoc false
    use Reactor

    input(:ids)
    input(:fx)

    map :each do
      source input(:ids)
      allow_async?(false)

      step :charge, Charge do
        argument :id, element(:each)
        argument :fx, input(:fx)
      end

      return :charge
    end

    return :each
  end

  defmodule Switched do
    @moduledoc false
    use Reactor

    input(:amount)
    input(:fx)

    switch :route do
      on input(:amount)
      allow_async?(false)

      matches? &(&1 > 100) do
        step :large, {Branch, tag: :large} do
          argument :amount, input(:amount)
          argument :fx, input(:fx)
        end

        return :large
      end

      default do
        step :small, {Branch, tag: :small} do
          argument :amount, input(:amount)
          argument :fx, input(:fx)
        end

        return :small
      end
    end

    return :route
  end

  defp mapped(_fx), do: Reactor.Info.to_struct!(Mapped)
  defp switched(_fx), do: Reactor.Info.to_struct!(Switched)

  defp run_reactor(store, run_id, reactor, inputs) do
    {:ok, _} =
      Ets.start_run(store, %{id: run_id, model: nil, bindings: %{}, inputs: %{}, context: %{}})

    cps = for {k, c} <- Ets.checkpoints(store, run_id), do: {k, c.output}

    durable = %{
      store: store,
      store_module: Ets,
      run_id: run_id,
      checkpoints: Map.new(cps)
    }

    reactor |> Run.decorate(durable) |> Reactor.run(inputs, %{}, [])
  end

  defp rerun(store, run_id, reactor, inputs) do
    cps = for {k, c} <- Ets.checkpoints(store, run_id), do: {k, c.output}
    durable = %{store: store, store_module: Ets, run_id: run_id, checkpoints: Map.new(cps)}
    reactor |> Run.decorate(durable) |> Reactor.run(inputs, %{}, [])
  end

  test "each element of a map checkpoints on its own", %{store: store, fx: fx} do
    assert {:ok, results} = run_reactor(store, "m1", mapped(fx), %{ids: ["a", "b", "c"], fx: fx})
    assert Enum.sort(results) == [charged: "a", charged: "b", charged: "c"]

    for id <- ["a", "b", "c"], do: assert(Effects.count(fx, {:charge, id}) == 1)
    # the map step itself plus one checkpoint per inlined child
    assert length(Ets.standing(store, "m1")) > 3
  end

  test "a replayed map re-runs no element that already recorded", %{store: store, fx: fx} do
    {:ok, first} = run_reactor(store, "m2", mapped(fx), %{ids: ["a", "b", "c"], fx: fx})
    before = Effects.all(fx)
    keys = store |> Ets.standing("m2") |> Enum.map(& &1.step_key)

    assert {:ok, second} = rerun(store, "m2", mapped(fx), %{ids: ["a", "b", "c"], fx: fx})
    assert second == first
    assert Effects.all(fx) == before
    # names are stable across attempts: a rebuilt reactor adds no new key
    assert store |> Ets.standing("m2") |> Enum.map(& &1.step_key) == keys
  end

  test "a recorded map replays its recorded result even if its input later changes", %{
    store: store,
    fx: fx
  } do
    {:ok, _} = run_reactor(store, "m3", mapped(fx), %{ids: ["a", "b"], fx: fx})
    assert {:ok, results} = rerun(store, "m3", mapped(fx), %{ids: ["a", "b", "c"], fx: fx})
    assert Enum.sort(results) == [charged: "a", charged: "b"]
    assert Effects.count(fx, {:charge, "a"}) == 1
    assert Effects.count(fx, {:charge, "b"}) == 1
    assert Effects.count(fx, {:charge, "c"}) == 0
  end

  test "step keys are the deterministic encoding of the reactor name" do
    assert Key.for_name({:each, 1}) == Key.for_name({:each, 1})
    refute Key.for_name({:each, 1}) == Key.for_name({:each, 2})
    refute Key.for_name(:a) == Key.for_name("a")
  end

  test "the branch a switch took is what records; the other never runs", %{store: store, fx: fx} do
    case run_reactor(store, "s1", switched(fx), %{amount: 500, fx: fx}) do
      {:ok, {:large, 500}} ->
        assert Effects.count(fx, :large) == 1
        assert Effects.count(fx, :small) == 0

      other ->
        flunk("switch fixture did not run as built: #{inspect(other)}")
    end
  end

  test "a switch keeps its branch on a later attempt", %{store: store, fx: fx} do
    {:ok, first} = run_reactor(store, "s2", switched(fx), %{amount: 10, fx: fx})
    assert {:ok, ^first} = rerun(store, "s2", switched(fx), %{amount: 10, fx: fx})
    assert Effects.count(fx, :small) == 1
    assert Effects.count(fx, :large) == 0
  end

  # --- nesting composites ---------------------------------------------------

  defp step(name, impl), do: %Reactor.Step{name: name, impl: impl, arguments: []}

  test "a durable wait inside a group is refused by the Verifier" do
    group =
      step(
        :grp,
        {Reactor.Step.Group, steps: [step(:wait, {Await, [signal: "go", timeout: nil]})]}
      )

    assert {:error, %{reason: :durable_step_in_nesting_composite, composite: :grp, step: :wait}} =
             Verifier.verify(%{Reactor.Builder.new() | steps: [group]})
  end

  test "a durable wait inside a map's inlined children is admitted (they share the outer plan)" do
    inner = step(:wait, {Await, [signal: "go", timeout: nil]})
    map = step(:each, {Reactor.Step.Map, steps: [inner]})
    assert :ok = Verifier.verify(%{Reactor.Builder.new() | steps: [map]})
  end
end
