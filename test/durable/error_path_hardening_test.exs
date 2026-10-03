defmodule AshPPlan.Reactor.Durable.ErrorPathHardeningTest do
  @moduledoc """
  Court: error paths of the durable ledger engine (`Engine`, `Status`, `Unwind`, `Store.Ets`).

  Covered: a signal for a run that does not exist (including any non-binary run id) is a typed
  error, not a stored orphan; non-binary run ids are typed refusals across the engine surface;
  a checkpoint whose stored `impl` snapshot is corrupt is reported unresolved, not crashed;
  a second failed rollback on an already-`:unwind_blocked` run records its FRESH error over
  the stale one (the `unwind_blocked` self-transition).

  Anti-vacuity mutations: revert `Engine.signal/5`'s existence check — the orphan-signal
  tests fail (a row is stored for a missing run); drop `unwind_blocked -> unwind_blocked`
  from `Status`'s allowed map — the fresh-error test fails with the stale error instead.

  Real `Store.Ets`, real Reactor steps, real Agents, no mocks.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Clock, Engine, Key, Unwind}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Effects
  alias AshPPlan.Realization
  alias AshPPlan.Workflow.Model

  @fx :errpath_fx_effects
  @state :errpath_fx_state
  @id_key AshPPlan.Reactor.context_key()

  defmodule Fx do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(_args, _ctx, opts) do
      effects = Keyword.fetch!(opts, :effects)
      effect = Keyword.fetch!(opts, :effect)

      case Effects.run(effects, effect) do
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

      if reason = Agent.get(state, & &1.undo_error) do
        {:error, reason}
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
    def id, do: :errpath_fx
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
      Map.put(Map.new(previous), :errpath_fx, Adapter)
    )

    on_exit(fn -> Application.put_env(:ash_pplan, :extra_adapters, previous) end)

    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    {:ok, _} = Effects.start_link(name: @fx)

    {:ok, _} =
      Agent.start_link(fn -> %{order: [], undo_error: nil, identity: nil} end, name: @state)

    {:ok, store} = Ets.start_link()
    {:ok, store: store}
  end

  defp attrs(id, tasks) do
    task_specs =
      tasks
      |> Enum.with_index()
      |> Enum.map(fn {{tid, cap, _op, _o}, i} ->
        base = [id: tid, capability: cap, authority: :construct]

        if i == 0 do
          base
        else
          base ++ [after: [elem(Enum.at(tasks, i - 1), 0)]]
        end
      end)

    {:ok, model} = Model.new(name: "errpath-#{id}", goal: "g", tasks: task_specs)

    bindings =
      Map.new(tasks, fn {tid, cap, op, extra} ->
        {tid,
         %Realization{
           capability: cap,
           provider: :errpath_fx,
           binding: %{adapter: :errpath_fx, op: op},
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

  defp undo_err(reason), do: Agent.update(@state, &%{&1 | undo_error: reason})

  # -- signals for runs that do not exist ------------------------------------------------------

  test "a signal for an unknown run is a typed error and stores no orphan row", %{store: s} do
    assert {:error, :no_such_run} = Engine.signal(s, "ghost", "go", :x)
    assert {:error, :no_such_run} = Engine.signal(s, 42, "go", :x)
    assert {:error, :no_such_run} = Engine.signal(s, nil, "go", :x)
    assert Ets.signals(s, "ghost") == []
    assert Ets.signals(s, 42) == []
  end

  test "a signal to an existing run is unchanged", %{store: s} do
    {:ok, _} = Engine.start(s, parked("sig1"))
    assert {:ok, %AshPPlan.Reactor.Durable.Signal{}} = Engine.signal(s, "sig1", "go", :x)
    assert [%{name: "go"}] = Ets.signals(s, "sig1")
  end

  # -- non-binary run ids ----------------------------------------------------------------------

  test "non-binary run ids are typed refusals across the engine surface", %{store: s} do
    {:ok, _} = Engine.start(s, parked("nb1"))
    assert Engine.attempt(s, 42) == :not_found
    assert {:error, :no_such_run} = Engine.cancel(s, nil)
    assert Engine.wake(s, 42) == :not_found
    assert {:error, [{:no_such_run, 42}]} = Unwind.run(s, 42)
  end

  # -- corrupt checkpoint payloads -------------------------------------------------------------

  test "a corrupt impl snapshot is reported unresolved, not crashed", %{store: s} do
    id = "corrupt-impl"
    ctx = %{@id_key => %{subject: "sha256:court", workflow: :court}}
    {:ok, _} = Ets.start_run(s, %{id: id, context: ctx})

    assert {:ok, _} =
             Ets.record(s, id, Key.for_name(:corrupt), "corrupt", :out, %{
               impl: {:bogus_tuple, 1},
               args: %{}
             })

    assert {:ok, ["corrupt"]} = Unwind.run(s, id)
  end

  test "a corrupt non-map args payload fails that undo and leaves the checkpoint standing", %{
    store: s
  } do
    id = "corrupt-args"
    ctx = %{@id_key => %{subject: "sha256:court", workflow: :court}}
    {:ok, _} = Ets.start_run(s, %{id: id, context: ctx})

    impl =
      {AshPPlan.Reactor.Durable.ErrorPathHardeningTest.Fx,
       [effects: @fx, state: @state, effect: :x]}

    {:ok, _} =
      Ets.record(s, id, Key.for_name(:badargs), Key.label(:badargs), :out, %{
        impl: impl,
        args: "not-a-map"
      })

    # the corrupt args reach the undo; the undo's own verdict decides, nothing crashes
    assert {:ok, []} = Unwind.run(s, id)
    assert Ets.standing(s, id) == []

    undo_err({:undo_refused, :badargs})

    {:ok, cp} =
      Ets.record(s, id, Key.for_name(:badargs2), Key.label(:badargs2), :out, %{
        impl: impl,
        args: "not-a-map"
      })

    assert cp != nil
    assert {:error, [{:undo_failed, _, {:undo_refused, :badargs}}]} = Unwind.run(s, id)
  end

  # -- second rollback failure on an already-blocked run ---------------------------------------

  test "a second failed rollback records its fresh error over the stale one", %{store: s} do
    {:ok, _} = Engine.start(s, parked("fresh-err"))
    assert {:parked, _} = Engine.attempt(s, "fresh-err")
    {:ok, _} = Engine.cancel(s, "fresh-err")

    undo_err({:undo_refused, :first})

    assert {:failed, [{:undo_failed, _, {:undo_refused, :first}} | _]} =
             Engine.attempt(s, "fresh-err")

    assert %{status: :unwind_blocked, error: first_error} = Engine.fetch(s, "fresh-err")
    assert Enum.any?(first_error, &match?({:undo_failed, _, {:undo_refused, :first}}, &1))

    undo_err({:undo_refused, :second})

    assert {:failed, [{:undo_failed, _, {:undo_refused, :second}} | _]} =
             Engine.attempt(s, "fresh-err")

    assert %{status: :unwind_blocked, error: second_error} = Engine.fetch(s, "fresh-err")
    assert Enum.any?(second_error, &match?({:undo_failed, _, {:undo_refused, :second}}, &1))
  end
end
