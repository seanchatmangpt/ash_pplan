defmodule AshPPlan.Reactor.Durable.StoreDifferentialTest do
  @moduledoc """
  Court: the two store implementations are interchangeable under a randomised workload.

  The same seeded random op sequence runs against `Store.Ets` and `Store.Dets`; after every
  op the two stores must expose identical observable state (run status, standing ledger
  order and outputs, pending signals). Real stores, real processes, no mocks.

  Anti-vacuity mutation: injecting an op that only one store honours (or divergent seq/order
  handling) flips this test — e.g. a store that dropped `record`'s insert-or-adopt losers
  would diverge on duplicate record ops.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.Store
  alias AshPPlan.Reactor.Durable.Store.{Dets, Ets}

  @ops 120

  setup do
    path = Path.join(System.tmp_dir!(), "sdiff-#{System.unique_integer([:positive])}.dets")
    {:ok, ets} = Ets.start_link()
    {:ok, dets} = Dets.start_link(path: path)

    on_exit(fn ->
      File.rm_rf(path)
      File.rm_rf(path <> ".backup")
    end)

    {:ok, ets: ets, dets: dets}
  end

  test "same seeded workload, identical observable state", %{ets: ets, dets: dets} do
    :rand.seed(:exsss, {101, 202_610, 1})

    run_ids = for i <- 1..3, do: "run-#{i}"

    # Start the same runs in both stores first.
    for id <- run_ids do
      attrs = %{
        id: id,
        plan_iri: "urn:test:sdiff",
        model: nil,
        bindings: %{},
        inputs: %{},
        context: %{}
      }

      assert {:ok, _} = Ets.start_run(ets, attrs)
      assert {:ok, _} = Dets.start_run(dets, attrs)
    end

    for op <- Stream.repeatedly(&draw_op/0) |> Enum.take(@ops) do
      apply_op(Ets, ets, op)
      apply_op(Dets, dets, op)

      assert_observation_equal(Ets, ets, Dets, dets, op)
    end
  end

  defp draw_op(n \\ 6) do
    case :rand.uniform(n) do
      1 -> {:record, :rand.uniform(3), "step-#{:rand.uniform(5)}", {:out, :rand.uniform(100)}}
      2 -> {:transition, :rand.uniform(3), :completed}
      3 -> {:transition, :rand.uniform(3), :waiting}
      4 -> {:deliver, :rand.uniform(3), "sig-#{:rand.uniform(3)}", :p}
      5 -> {:consume, :rand.uniform(3), "sig-#{:rand.uniform(3)}"}
      6 -> {:duplicate_record, :rand.uniform(3), "step-#{:rand.uniform(5)}"}
    end
  end

  defp apply_op(mod, store, {:record, n, step, out}) do
    id = "run-#{n}"
    mod.record(store, id, key(step), step, out, %{name: String.to_atom(step)})
    :ok
  end

  defp apply_op(mod, store, {:transition, n, to}),
    do: mod.transition(store, "run-#{n}", :any, to, %{})

  defp apply_op(mod, store, {:deliver, n, name, p}),
    do: mod.deliver_signal(store, "run-#{n}", name, p)

  defp apply_op(mod, store, {:consume, n, name}) do
    case mod.pending_signal(store, "run-#{n}", name) do
      nil -> :ok
      sig -> mod.consume_signal(store, sig.id, AshPPlan.Reactor.Durable.Clock.now())
    end
  end

  defp apply_op(mod, store, {:duplicate_record, n, step}) do
    mod.record(store, id(n), key(step), step, :dup, %{name: String.to_atom(step)})
    :ok
  end

  defp apply_op(_mod, _store, _other), do: :ok

  defp id(n), do: "run-#{n}"

  defp key(step), do: :crypto.hash(:sha256, step)

  defp assert_observation_equal(ma, sa, mb, sb, op) do
    {n, _step} =
      case op do
        {kind, n} when kind in [:transition] -> {n, nil}
        {kind, n, _x} when kind in [:deliver, :consume, :duplicate_record] -> {n, nil}
        {kind, n, _s, _o} when kind in [:record] -> {n, nil}
        _ -> {1, nil}
      end

    id = "run-#{n}"

    ra = ma.get_run(sa, id)
    rb = mb.get_run(sb, id)
    assert Map.get(ra, :status) == Map.get(rb, :status), "status divergence on #{id}"

    la = standing_view(ma, sa, id)
    lb = standing_view(mb, sb, id)
    assert la == lb, "standing divergence on #{id}: #{inspect(la)} vs #{inspect(lb)}"

    sigs_a = pending_view(ma, sa, id)
    sigs_b = pending_view(mb, sb, id)
    assert sigs_a == sigs_b
  end

  defp standing_view(mod, store, id) do
    mod.standing(store, id)
    |> Enum.map(&{&1.label, &1.output, is_nil(&1.undone_at)})
  end

  defp pending_view(mod, store, id) do
    mod.signals(store, id)
    |> Enum.filter(&is_nil(&1.consumed_at))
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end
end
