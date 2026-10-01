defmodule AshPPlan.Reactor.Durable.AdversarialUnwindTest do
  @moduledoc """
  Adversarial court (audit a1) for `Unwind` and the terminal-state absorption of `Engine`/`Store.Ets`.

  Real `Store.Ets`, real `Engine`, real Reactor; no mocks. Probes: the context handed to undo
  (step identity), a stranded `:unwind_blocked` run, an in-run rollback whose undo fails, a late
  checkpoint written to a terminal run, map/switch children stored with tuple names, and
  terminal absorption.

  Anti-vacuity mutation: changing `Unwind.undo_checkpoint` to skip `claim_undo` fails the
  exactly-once test; widening `Status.@allowed` for completed fails the absorption test.

  Design derived from mbuhot/magma (MIT per its mix.exs).
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Clock, Engine, Key, Status, Unwind}
  alias AshPPlan.Reactor.Durable.Store.Ets

  @log :adv_unwind_log
  @id_key AshPPlan.Reactor.context_key()

  defmodule S do
    @moduledoc false
    use Reactor.Step
    @impl true
    def run(_a, _c, _o), do: {:ok, :done}

    @impl true
    def undo(_value, _args, context, opts) do
      name = Keyword.fetch!(opts, :name)

      if Agent.get(:adv_unwind_log, & &1.fail?) do
        {:error, :refused}
      else
        Agent.update(:adv_unwind_log, fn s ->
          %{s | order: s.order ++ [{name, context.current_step.name}]}
        end)

        :ok
      end
    end
  end

  setup do
    {:ok, _} = Agent.start_link(fn -> %{order: [], fail?: false} end, name: @log)
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    {:ok, store} = Ets.start_link([])
    {:ok, store: store}
  end

  defp ctx, do: %{@id_key => %{subject: "sha256:adv", workflow: :adv}}

  defp run!(s, id) do
    {:ok, _} = Engine.start(s, %{id: id, context: ctx()})
    id
  end

  defp stand(s, id, name) do
    {:ok, cp} =
      Ets.record(s, id, Key.for_name(name), Key.label(name), :out, %{
        impl: {S, [name: name]},
        args: %{}
      })

    cp
  end

  test "undo sees the original step name (map/switch tuple names), not the label string", %{
    store: s
  } do
    id = run!(s, "n1")
    stand(s, id, {:map_el, :items, 3})
    assert {:ok, []} = Unwind.run(s, id)
    [{name, current}] = Agent.get(@log, & &1.order)
    assert current == name
  end

  test "unwind_blocked run is resumable once the cause is fixed", %{store: s} do
    id = run!(s, "b1")
    stand(s, id, :a)
    Agent.update(@log, &%{&1 | fail?: true})
    {:ok, _} = Engine.cancel(s, id)
    assert {:failed, _} = Engine.attempt(s, id)
    assert Ets.get_run(s, id).status == :unwind_blocked

    Agent.update(@log, &%{&1 | fail?: false})
    # a fixed rollback must be finishable through the engine's own entry points
    _ = Engine.cancel(s, id)
    result = Engine.attempt(s, id)
    assert result == {:rolled_back, :cancelled}
    assert Ets.get_run(s, id).status == :cancelled
    assert Ets.standing(s, id) == []
  end

  test "a terminal run never accepts a new checkpoint (no unreachable standing effects)", %{
    store: s
  } do
    id = run!(s, "t1")
    {:ok, _} = Engine.cancel(s, id)
    assert {:rolled_back, :cancelled} = Engine.attempt(s, id)

    late =
      Ets.record(s, id, Key.for_name(:late), "late", :x, %{impl: {S, [name: :late]}, args: %{}})

    refute match?({:ok, _}, late)
    assert Ets.standing(s, id) == []
  end

  test "terminal states are absorbing at the store and the engine", %{store: s} do
    for target <- [:completed, :failed, :cancelled], to <- Status.all() do
      refute Status.can?(target, to)
    end

    id = run!(s, "t2")
    {:ok, _} = Ets.transition(s, id, [:pending], :completed, %{result: 1})
    assert {:error, _} = Ets.transition(s, id, :any, :failed, %{})
    assert {:error, _} = Ets.transition(s, id, [:completed], :pending, %{})
    assert {:error, :not_cancellable} = Engine.cancel(s, id)
    assert :ended = Engine.attempt(s, id)
    assert Ets.get_run(s, id).status == :completed
    assert Ets.get_run(s, id).result == 1
  end

  test "a terminal run that still has a claim is not runnable and a claim cannot revive it", %{
    store: s
  } do
    id = run!(s, "t3")
    {:ok, _} = Ets.transition(s, id, [:pending], :failed, %{error: :x})
    _ = Ets.claim(s, id, "c", 30_000, Clock.now())
    refute Engine.runnable?(s, Ets.get_run(s, id), Clock.now())
    assert Engine.runnable(s, Clock.now()) == []
  end

  test "exactly-once undo when a rollback is cancelled-then-attempted concurrently", %{store: s} do
    id = run!(s, "x1")
    for n <- [:a, :b, :c], do: stand(s, id, n)
    {:ok, _} = Engine.cancel(s, id)

    1..6
    |> Enum.map(fn _ -> Task.async(fn -> Engine.attempt(s, id) end) end)
    |> Task.await_many(10_000)

    assert Enum.sort(Enum.map(Agent.get(@log, & &1.order), &elem(&1, 0))) == [:a, :b, :c]
    assert Ets.get_run(s, id).status == :cancelled
  end

  test "stored impl whose module is gone is reported unresolved, not crashed", %{store: s} do
    id = run!(s, "g1")

    {:ok, _} =
      Ets.record(s, id, Key.for_name(:gone), "gone", :x, %{impl: {Nope.Missing, []}, args: %{}})

    assert {:ok, ["gone"]} = Unwind.run(s, id)
  end
end
