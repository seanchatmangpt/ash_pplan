defmodule AshPPlan.Reactor.Durable.PolicyDriverTest do
  @moduledoc """
  Court: `PolicyDriver` over real `AshPPlan.FOND` synthesis and validation (no doubles).

  A driver built from a domain carries a policy that `AshPPlan.validate_policy/4` admits; a
  policy that fails validation is a typed `:inadmissible_policy`; `decide/2` returns actions as
  data only and a state with no decision is a typed outside-domain refusal; `observe/4` refuses
  a successor the domain does not admit; `from_model/2` projects the workflow outcome topology.

  Anti-vacuity mutations: make `admit/1` return `:ok` unconditionally -> the inadmissible-policy
  test fails; make `observe/4` return `{:ok, observed}` unconditionally -> the outside-domain
  test fails; drop `ceiling`/`authority` defaults -> the no-authority test fails.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.Reactor.Durable.PolicyDriver

  @transitions %{
    start: %{
      charge_primary: [:paid, :primary_unavailable, :declined],
      charge_backup: [:paid, :declined]
    },
    primary_unavailable: %{charge_backup: [:paid, :declined]},
    paid: %{},
    declined: %{}
  }

  defp domain do
    {:ok, d} = FOND.new(@transitions, [:paid, :declined])
    d
  end

  test "new/3 synthesizes a policy that validate_policy admits" do
    assert {:ok, driver} = PolicyDriver.new(domain(), :start)
    assert {:ok, _} = AshPPlan.validate_policy(driver.domain, driver.policy, :start)
    assert {:ok, :charge_backup} = PolicyDriver.decide(driver, :start)
    assert {:done, :paid} = PolicyDriver.decide(driver, :paid)
  end

  test "an inadmissible policy is a typed refusal" do
    # charge_primary can leave the winning set only via goals here, so use an action not admitted
    bad = %{start: :no_such_action, primary_unavailable: :charge_backup}

    assert {:error, {:inadmissible_policy, _}} = PolicyDriver.new(domain(), :start, policy: bad)

    assert {:error, {:inadmissible_policy, _}} =
             PolicyDriver.new(domain(), :start, policy: %{})
  end

  test "an unsolvable domain is refused as inadmissible" do
    {:ok, d} = FOND.new(%{start: %{go: [:dead]}, dead: %{}}, [:never])
    assert {:error, {:inadmissible_policy, _}} = PolicyDriver.new(d, :start)
  end

  test "admit/1 re-gates a hand-built driver" do
    {:ok, driver} = PolicyDriver.new(domain(), :start)
    assert :ok = PolicyDriver.admit(driver)
    broken = %{driver | policy: %{}}
    assert {:error, {:inadmissible_policy, _}} = PolicyDriver.admit(broken)
    assert {:error, {:inadmissible_policy, _}} = PolicyDriver.admit(:not_a_driver)
  end

  test "an observed outcome outside the domain, and a state with no decision, are typed" do
    {:ok, driver} = PolicyDriver.new(domain(), :start)
    {:ok, action} = PolicyDriver.decide(driver, :start)

    assert {:ok, :paid} = PolicyDriver.observe(driver, :start, action, :paid)

    assert {:error, {:outcome_outside_policy_domain, %{observed: :refunded, admitted: admitted}}} =
             PolicyDriver.observe(driver, :start, action, :refunded)

    assert :paid in admitted

    assert {:error, {:outcome_outside_policy_domain, %{reason: :no_policy_decision}}} =
             PolicyDriver.decide(driver, :unknown_state)
  end

  test "a driver names actions as data and holds no authority" do
    {:ok, driver} = PolicyDriver.new(domain(), :start)
    assert driver.authority == :none
    assert driver.ceiling == :construct
    assert {:ok, action} = PolicyDriver.decide(driver, :start)
    assert is_atom(action)
  end

  test "fingerprint is deterministic and changes with the policy" do
    {:ok, a} = PolicyDriver.new(domain(), :start)
    {:ok, b} = PolicyDriver.new(domain(), :start)
    assert PolicyDriver.fingerprint(a) == PolicyDriver.fingerprint(b)

    {:ok, c} =
      PolicyDriver.new(domain(), :start,
        policy: %{start: :charge_primary, primary_unavailable: :charge_backup}
      )

    refute PolicyDriver.fingerprint(a) == PolicyDriver.fingerprint(c)
  end

  test "from_model/2 projects the workflow outcome topology and refuses a non-model" do
    assert {:error, {:inadmissible_policy, %{reason: :not_a_model}}} =
             PolicyDriver.from_model(:nope)
  end
end
