defmodule AshPPlan.FONDSubjectTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Subject

  test "exact subject identity is deterministic and mode-sensitive" do
    {:ok, domain} =
      FOND.new(%{pending: %{attempt: [:pending, :done]}, done: %{}}, [:done])

    policy = %{pending: :attempt}
    a = Subject.bind(domain, policy, :pending, :strong)
    b = Subject.bind(domain, policy, :pending, :strong)
    c = Subject.bind(domain, policy, :pending, :strong_cyclic)

    assert a.id == b.id
    assert a.digest == b.digest
    refute a.id == c.id
    assert String.starts_with?(a.id, "sha256:")
    assert a.state_count == 2
  end

  test "transition insertion order does not change identity" do
    {:ok, left} =
      FOND.new(
        %{
          a: %{go: [:c, :b]},
          b: %{go: [:done]},
          c: %{go: [:done]},
          done: %{}
        },
        [:done]
      )

    {:ok, right} =
      FOND.new(
        %{
          done: %{},
          c: %{go: [:done]},
          b: %{go: [:done]},
          a: %{go: [:b, :c]}
        },
        [:done]
      )

    policy = %{a: :go, b: :go, c: :go}
    assert Subject.bind(left, policy, :a, :strong).id ==
             Subject.bind(right, policy, :a, :strong).id
  end

  test "colliding term spelling: 1 vs 1.0 binds the same subject id" do
    {:ok, int_spelled} = FOND.new(%{:a => %{go: [1]}, 1 => %{}}, [1])
    {:ok, float_spelled} = FOND.new(%{:a => %{go: [1.0]}, 1 => %{}}, [1])

    policy = %{a: :go}

    int_subject = Subject.bind(int_spelled, policy, :a, :strong)
    float_subject = Subject.bind(float_spelled, policy, :a, :strong)

    assert int_subject.id == float_subject.id
    assert Subject.same?(int_subject, float_subject)
  end
end
