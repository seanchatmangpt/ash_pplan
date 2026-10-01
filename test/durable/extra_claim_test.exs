defmodule AshPPlan.Reactor.Durable.ExtraClaimTest do
  @moduledoc """
  Court (magma-derived): claim and lease semantics at the Engine seam.

  Four concurrent attempts with distinct claimers run each step once; a lapsed lease is taken over
  and replays; the same claimer re-enters its own live claim; a nil claimer never re-enters (it
  is taken even by itself); a claim is released only after the outcome is written; parallel branches
  stay independent and replay returns identical values.

  Real Engine, `Store.Ets`, Reactor, test `Clock`. Anti-vacuity mutation (run manually): make
  `Ets.claim/5` treat a nil claimer as re-entrant -> the nil-claimer test fails; drop the claim call
  in `Engine.claim_and_run/4` -> the concurrent test counts > 1 per step.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Clock, Engine, Run}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.{Effects, ExtraFx}

  setup do
    ExtraFx.install_adapter!()
    Clock.use_test_clock(~U[2026-01-01 00:00:00Z])
    on_exit(&Clock.reset/0)
    fx = :"fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)
    {:ok, store} = Ets.start_link()
    {:ok, store: store, fx: fx}
  end

  defp start(store, id, fx, extra \\ %{}),
    do: {:ok, _} = Engine.start(store, ExtraFx.attrs(id, fx, extra))

  @once %{root: 1, left: 1, right: 1, join: 1}

  test "four concurrent attempts with distinct claimers run each step once", %{store: s, fx: fx} do
    start(s, "c1", fx)

    outcomes =
      1..4
      |> Enum.map(fn n -> Task.async(fn -> Engine.attempt(s, "c1", claimer: {:w, n}) end) end)
      |> Task.await_many(15_000)

    assert Enum.count(outcomes, &match?({:completed, _}, &1)) == 1
    assert Enum.all?(outcomes, &(match?({:completed, _}, &1) or &1 in [:taken, :ended]))
    assert Effects.all(fx) == @once
    assert Engine.fetch(s, "c1").claimed_by == nil
  end

  test "a lapsed lease is taken over and the new attempt replays rather than repeats",
       %{store: s, fx: fx} do
    start(s, "c2", fx)
    {:ok, _} = Ets.claim(s, "c2", :ghost, 1_000, Clock.now())
    assert Engine.attempt(s, "c2", claimer: :new) == :taken
    Clock.advance(1_001)
    assert {:completed, _} = Engine.attempt(s, "c2", claimer: :new)
    assert Effects.all(fx) == @once
  end

  test "the same claimer re-enters its own live claim", %{store: s, fx: fx} do
    start(s, "c3", fx)
    {:ok, _} = Ets.claim(s, "c3", :me, 30_000, Clock.now())
    assert {:completed, _} = Engine.attempt(s, "c3", claimer: :me)
    assert Effects.all(fx) == @once
  end

  test "a nil claimer never re-enters, even its own claim", %{store: s, fx: fx} do
    start(s, "c4", fx)
    {:ok, _} = Ets.claim(s, "c4", nil, 30_000, Clock.now())
    assert Engine.attempt(s, "c4", claimer: nil) == :taken
    assert Engine.attempt(s, "c4", claimer: :someone) == :taken
    assert Effects.all(fx) == %{}
    Clock.advance(30_000)
    assert {:completed, _} = Engine.attempt(s, "c4", claimer: :someone)
  end

  test "a failed attempt releases its claim so the next attempt can run", %{store: s, fx: fx} do
    start(s, "c5", fx)
    Effects.fail_after(fx, :join, 0)
    assert Engine.attempt(s, "c5", claimer: :a) != :taken
    assert Engine.fetch(s, "c5").claimed_by == nil
    assert Engine.attempt(s, "c5", claimer: :b) in [:ended, {:rolled_back, :failed}]
  end

  test "parallel branches are independent: a failing branch leaves its sibling recorded",
       %{store: s, fx: fx} do
    {:ok, rec} = Engine.start(s, ExtraFx.attrs("c6", fx))
    Effects.fail_after(fx, :right, 0)
    assert {:error, _} = Run.run(s, rec)
    assert Effects.count(fx, :root) == 1
    assert Effects.count(fx, :right) == 0
    assert Effects.count(fx, :join) == 0

    Effects.fail_after(fx, :right, 99)
    assert {:ok, _} = Run.run(s, Ets.get_run(s, "c6"))
    assert Effects.all(fx) == @once
  end

  test "replay returns identical values and records no new checkpoint", %{store: s, fx: fx} do
    {:ok, rec} = Engine.start(s, ExtraFx.attrs("c7", fx))
    assert {:ok, first} = Run.run(s, rec)
    tape = Ets.standing(s, "c7") |> Enum.map(&{&1.step_key, &1.output})

    for _ <- 1..3, do: assert({:ok, ^first} = Run.run(s, Ets.get_run(s, "c7")))

    assert Ets.standing(s, "c7") |> Enum.map(&{&1.step_key, &1.output}) == tape
    assert Effects.all(fx) == @once
  end
end
