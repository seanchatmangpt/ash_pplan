defmodule AshPPlan.Reactor.Durable.RunTest do
  @moduledoc """
  Court: `Run` + `Checkpointed` + `Middleware` record what stands and replay it through the impl.

  Real Reactor, real `Store.Ets`, real counting steps in a registered `Effects` agent; no mocks.

  Anti-vacuity mutations (each flips a named test): remove the `Run.recorded/2` lookup in
  `Checkpointed.run/3` -> "second run re-executes nothing" and "resume after failure" fail;
  drop `neutralise/2` in `Run.decorate_step/2` -> "recorded step ignores a changed guard" fails;
  record the output the step produced instead of the output that stands -> the
  "replay value equals original" test still passes but `worker_claim_test` double-run fails.
  """
  use ExUnit.Case, async: false

  Code.require_file("lane_b_fixture.exs", __DIR__)

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.{Checkpointed, Clock, Engine, Middleware, Run, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Effects

  setup do
    LaneBFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    name = :"fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: name)
    {:ok, store} = Ets.start_link()
    {:ok, store: store, fx: name}
  end

  defp start(store, id, fx, opts \\ []) do
    {:ok, rec} = Engine.start(store, LaneBFx.attrs(id, fx, opts))
    rec
  end

  test "records every step", %{store: store, fx: fx} do
    start(store, "r1", fx)
    assert {:completed, _} = Engine.attempt(store, "r1")
    assert length(Testing.tape(store, "r1")) == 5
    assert LaneBFx.counts(fx) == %{observe: 1, select: 1, execute: 1, integrate: 1, verify: 1}
  end

  test "second run re-executes nothing and replays the same value", %{store: store, fx: fx} do
    rec = start(store, "r2", fx)
    assert {:ok, first} = Run.run(store, rec)
    before = LaneBFx.counts(fx)
    assert {:ok, second} = Run.run(store, Ets.get_run(store, "r2"))
    assert LaneBFx.counts(fx) == before
    assert second == first
    assert length(Ets.standing(store, "r2")) == 5
  end

  test "resume after failure repeats no finished step", %{store: store, fx: fx} do
    rec = start(store, "r3", fx)
    Effects.fail_after(fx, :verify, 0)
    assert {:error, _} = Run.run(store, rec)
    assert LaneBFx.counts(fx) == %{observe: 1, select: 1, execute: 1, integrate: 1}

    Effects.fail_after(fx, :verify, 99)
    assert {:ok, _} = Run.run(store, Ets.get_run(store, "r3"))
    assert LaneBFx.counts(fx) == %{observe: 1, select: 1, execute: 1, integrate: 1, verify: 1}
  end

  test "parallel branches are independent: a failing branch leaves its sibling recorded", %{
    store: store,
    fx: fx
  } do
    rec = start(store, "r4", fx, shape: :parallel)
    Effects.fail_after(fx, :right, 0)
    assert {:error, _} = Run.run(store, rec)
    assert Effects.count(fx, :root) == 1
    assert Effects.count(fx, :right) == 0

    Effects.fail_after(fx, :right, 99)
    assert {:ok, _} = Run.run(store, Ets.get_run(store, "r4"))
    assert LaneBFx.counts(fx) == %{root: 1, left: 1, right: 1, join: 1}
  end

  defmodule Counted do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(_a, _c, opts) do
      {:ok, Effects.run(Keyword.fetch!(opts, :fx), :guarded) |> elem(1)}
    end
  end

  test "a recorded step ignores a changed guard", %{store: store, fx: fx} do
    {:ok, _} = Engine.start(store, %{id: "g1", model: nil})
    :persistent_term.put({__MODULE__, :open}, true)
    on_exit(fn -> :persistent_term.erase({__MODULE__, :open}) end)

    guard = %Reactor.Guard{
      fun: fn _args, _ctx ->
        if :persistent_term.get({__MODULE__, :open}), do: :cont, else: {:halt, {:ok, :skipped}}
      end
    }

    {:ok, reactor} =
      Reactor.Builder.add_step(Reactor.Builder.new(), :guarded, {Counted, fx: fx}, [],
        guards: [guard]
      )

    {:ok, reactor} = Reactor.Builder.return(reactor, :guarded)

    run = fn ->
      mod = Ets
      cps = for {k, c} <- mod.checkpoints(store, "g1"), do: {k, c.output}
      durable = %{store: store, store_module: mod, run_id: "g1", checkpoints: Map.new(cps)}
      reactor |> Run.decorate(durable) |> Reactor.run(%{}, %{}, [])
    end

    assert {:ok, 1} = run.()
    :persistent_term.put({__MODULE__, :open}, false)
    # the guard now says halt, but the step already stands: it replays rather than skips
    assert {:ok, 1} = run.()
    assert Effects.count(fx, :guarded) == 1
  end

  test "decorate wraps every step, prepends the middleware and leaves a compose run-half alone" do
    plain = %Reactor.Step{name: :a, impl: {Counted, []}, arguments: []}
    compose = %Reactor.Step{name: {:compose, :x}, impl: {Counted, []}, arguments: []}
    reactor = %{Reactor.Builder.new() | steps: [plain, compose]}

    out = Run.decorate(reactor, %{store: self(), run_id: "x", checkpoints: %{}})
    assert hd(out.middleware) == Middleware
    [wrapped, untouched] = out.steps
    assert {Checkpointed, opts} = wrapped.impl
    assert opts[:durable_inner] == {Counted, []} and opts[:durable_name] == :a
    assert untouched.impl == {Counted, []}
    # idempotent
    assert Run.decorate_step(wrapped, %{}) == wrapped
  end

  test "a nesting-step guard: assert_own_step! raises when the step is not the running one" do
    inner = %Reactor.Step{name: :in, impl: {Counted, []}, arguments: []}
    outer = %Reactor.Step{name: :out, impl: {Counted, []}, arguments: []}
    assert :ok = Run.assert_own_step!(%{durable_step: inner, current_step: inner}, "Await")

    assert_raise RuntimeError, ~r/nesting composite/, fn ->
      Run.assert_own_step!(%{durable_step: outer, current_step: inner}, "Await")
    end
  end

  test "an error nothing can compensate is recorded as the run's cause before rollback", %{
    store: store,
    fx: fx
  } do
    rec = start(store, "r5", fx)
    Effects.fail_after(fx, :verify, 0)
    assert {:error, _} = Run.run(store, rec)
    run = Ets.get_run(store, "r5")
    assert run.status == :unwinding
    assert run.error != nil
  end
end
