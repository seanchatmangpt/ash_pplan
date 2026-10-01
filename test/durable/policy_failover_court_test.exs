defmodule AshPPlan.Reactor.Durable.PolicyFailoverCourtTest do
  @moduledoc """
  Court: the engine driven by a FOND policy (`Engine.drive_policy/3`, `attempt(policy:)`) over the
  real `Store.Ets` and the real `AshPPlan.Test.Effects` agent as the provider.

  Asserts on final state: a primary outage fails over to the backup and reaches the goal; a
  decline stops (a goal) without calling the backup; an inadmissible policy is refused before any
  provider call; an outcome outside the domain is a typed refusal that records no decision; each
  decision is a ledger checkpoint and a re-drive replays it without calling the provider again;
  replay under a different policy is a typed divergence; the policy itself grants nothing.

  Anti-vacuity mutations: skip `PolicyDriver.admit/1` in `drive_policy/3` -> the inadmissible
  court sees provider calls; skip `observe/4` -> the outside-domain court completes instead of
  refusing; stop recording decisions -> the replay court sees a second provider call; drop the
  fingerprint comparison in `replay_decision/4` -> the divergence court completes.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.FOND
  alias AshPPlan.Reactor.Durable.{Clock, Engine, PolicyDriver, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Effects

  @transitions %{
    start: %{
      charge_primary: [:paid, :primary_unavailable, :declined],
      charge_backup: [:paid, :declined]
    },
    primary_unavailable: %{charge_backup: [:paid, :declined]},
    paid: %{},
    declined: %{}
  }

  setup do
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    name = :"pol_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: name)
    {:ok, store} = Ets.start_link()
    {:ok, d} = FOND.new(@transitions, [:paid, :declined])
    {:ok, driver} = PolicyDriver.new(d, :start)

    {:ok, primary_first} =
      PolicyDriver.new(d, :start,
        policy: %{start: :charge_primary, primary_unavailable: :charge_backup}
      )

    {:ok, store: store, fx: name, driver: driver, primary_first: primary_first}
  end

  # A real provider: the script says what each provider answers; every call is counted.
  defp provider(fx, script) do
    fn action, _ctx ->
      {:ok, _} = Effects.run(fx, action)
      {:ok, Map.fetch!(script, action)}
    end
  end

  defp calls(fx, action), do: Effects.count(fx, action)

  defp run!(store, id) do
    {:ok, _} = Engine.start(store, %{id: id})
    id
  end

  test "primary unavailable fails over to the backup and reaches the goal", c do
    id = run!(c.store, "f1")
    script = %{charge_primary: :primary_unavailable, charge_backup: :paid}

    assert {:completed, %{goal: :paid, decisions: decisions}} =
             Engine.drive_policy(c.store, id,
               policy: c.primary_first,
               execute: provider(c.fx, script)
             )

    assert Enum.map(decisions, & &1.action) == [:charge_primary, :charge_backup]
    assert calls(c.fx, :charge_primary) == 1
    assert calls(c.fx, :charge_backup) == 1
    assert Testing.status(c.store, id) == :completed
  end

  test "primary success needs no backup; decline stops without calling the backup", c do
    driver = c.primary_first
    id = run!(c.store, "f2")

    assert {:completed, %{goal: :declined}} =
             Engine.drive_policy(c.store, id,
               policy: driver,
               execute: provider(c.fx, %{charge_primary: :declined, charge_backup: :declined})
             )

    assert calls(c.fx, :charge_backup) + calls(c.fx, :charge_primary) == 1
  end

  test "an inadmissible policy is refused before any provider call", c do
    bad = %{c.driver | policy: %{}}
    id = run!(c.store, "f3")

    assert {:refused, {:inadmissible_policy, _}} =
             Engine.drive_policy(c.store, id,
               policy: bad,
               execute: provider(c.fx, %{charge_primary: :paid})
             )

    assert {:refused, {:inadmissible_policy, _}} = Engine.attempt(c.store, id, policy: bad)
    assert calls(c.fx, :charge_primary) == 0
    assert Engine.steps(c.store, id) == []
    assert Testing.status(c.store, id) == :pending
  end

  test "an outcome outside the policy domain is a typed refusal and records nothing", c do
    id = run!(c.store, "f4")

    assert {:refused, {:outcome_outside_policy_domain, %{observed: :chargeback}}} =
             Engine.drive_policy(c.store, id,
               policy: c.primary_first,
               execute: provider(c.fx, %{charge_primary: :chargeback})
             )

    assert Engine.steps(c.store, id) == []
    assert Testing.status(c.store, id) == :pending
  end

  test "each decision is a ledger checkpoint; re-driving replays without calling the provider",
       c do
    id = run!(c.store, "f5")
    script = %{charge_primary: :primary_unavailable, charge_backup: :paid}
    exec = provider(c.fx, script)

    # Park the run mid-way by making the backup step crash the execute fn once.
    flaky = fn action, ctx ->
      if action == :charge_backup and calls(c.fx, :charge_backup) == 0 do
        {:ok, _} = Effects.run(c.fx, :charge_backup)
        raise "crash after effect"
      else
        exec.(action, ctx)
      end
    end

    primary_first = c.primary_first

    assert_raise RuntimeError, fn ->
      Engine.drive_policy(c.store, id, policy: primary_first, execute: flaky)
    end

    assert [%{output: %{action: :charge_primary, observed: :primary_unavailable}}] =
             Engine.steps(c.store, id)

    assert calls(c.fx, :charge_primary) == 1

    assert {:completed, %{goal: :paid, decisions: [_, _]}} =
             Engine.drive_policy(c.store, id, policy: primary_first, execute: exec)

    assert calls(c.fx, :charge_primary) == 1
    assert [%{step: 0}, %{step: 1}] = Enum.map(Engine.steps(c.store, id), & &1.output)
  end

  test "replay under a different policy is a typed divergence", c do
    id = run!(c.store, "f6")

    primary_first = c.primary_first

    boom = fn action, ctx ->
      case action do
        :charge_primary -> provider(c.fx, %{charge_primary: :primary_unavailable}).(action, ctx)
        _ -> raise "stop"
      end
    end

    assert_raise RuntimeError, fn ->
      Engine.drive_policy(c.store, id, policy: primary_first, execute: boom)
    end

    assert {:refused, {:policy_replay_divergence, %{step: 0}}} =
             Engine.drive_policy(c.store, id,
               policy: c.driver,
               execute: provider(c.fx, %{charge_backup: :paid})
             )

    assert calls(c.fx, :charge_backup) == 0
  end

  test "the policy grants no authority and the driver is plain data", c do
    assert c.driver.authority == :none
    assert c.driver.ceiling == :construct
    refute Enum.any?(Map.keys(c.driver), &(&1 in [:lease, :token, :credential]))
  end
end
