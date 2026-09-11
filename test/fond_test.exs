defmodule AshPPlan.FONDTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND

  test "strong-cyclic policy admits a fair retry cycle that strong semantics refuse" do
    {:ok, domain} =
      FOND.new(
        %{
          pending: %{attempt: [:pending, :succeeded]},
          succeeded: %{}
        },
        [:succeeded]
      )

    policy = %{pending: :attempt}

    assert {:ok, report} = FOND.validate_policy(domain, policy, :pending, :strong_cyclic)
    assert report.semantics == :strong_cyclic
    assert report.reachable_states == [:pending, :succeeded]

    assert {:error, %{reason: :not_strong, losing_states: [:pending]}} =
             FOND.validate_policy(domain, policy, :pending, :strong)
  end

  test "strong policy requires every nondeterministic successor to be winning" do
    {:ok, domain} =
      FOND.new(
        %{
          pending: %{finish: [:succeeded, :failed]},
          succeeded: %{},
          failed: %{}
        },
        [:succeeded, :failed]
      )

    assert {:ok, %{semantics: :strong}} =
             FOND.validate_policy(domain, %{pending: :finish}, :pending, :strong)
  end

  test "strong-cyclic refuses a reachable closed component with no goal path" do
    {:ok, domain} =
      FOND.new(
        %{
          pending: %{attempt: [:stuck]},
          stuck: %{retry: [:stuck]},
          succeeded: %{}
        },
        [:succeeded]
      )

    assert {:error,
            %{
              reason: :not_strong_cyclic,
              states_without_goal_path: [:pending, :stuck]
            }} =
             FOND.validate_policy(
               domain,
               %{pending: :attempt, stuck: :retry},
               :pending,
               :strong_cyclic
             )
  end

  test "policy validation fails closed on a missing or unavailable action" do
    {:ok, domain} = FOND.new(%{pending: %{attempt: [:succeeded]}, succeeded: %{}}, [:succeeded])

    assert {:error, %{reason: :missing_policy_action, state: :pending}} =
             FOND.validate_policy(domain, %{}, :pending)

    assert {:error,
            %{
              reason: :unavailable_policy_action,
              state: :pending,
              action: :invented,
              available: [:attempt]
            }} = FOND.validate_policy(domain, %{pending: :invented}, :pending)
  end

  test "empty nondeterministic outcomes are refused at admission" do
    assert {:error,
            %{reason: :empty_nondeterministic_outcome, state: :pending, action: :attempt}} =
             FOND.new(%{pending: %{attempt: []}}, [])
  end
end
