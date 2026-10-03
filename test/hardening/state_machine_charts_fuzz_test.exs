defmodule AshPPlan.Hardening.StateMachineChartsFuzzTest do
  @moduledoc """
  P2a fuzz court for `AshPPlan.StateMachine.Charts.render/1,2`. Law: typed
  refusal map or a rendered diagram string — never a raise — across random
  atoms, non-resource modules, garbage terms, and random diagram types.
  Seeded deterministic sweep (no stream_data in deps).
  """

  use ExUnit.Case, async: true

  alias AshPPlan.StateMachine.Charts

  @resource AshPPlan.StateMachineChartsIntegrationResource

  @garbage [
    nil,
    42,
    1.5,
    "resource",
    "",
    <<0, 255>>,
    :ok,
    :undefined,
    self(),
    {1, 2},
    {:t},
    [],
    [:a],
    %{},
    %{a: 1},
    {:ok, :nested},
    &String.length/1,
    <<1::1>>
  ]

  @types [:state, :flow, :gantt, :bogus, nil, 42, "state", {:state}, [:state], %{}]

  defp seed, do: {77, 500_000, 400_000}

  defp rng do
    :rand.seed(:exsss, seed())
    fn n -> :rand.uniform(n) - 1 end
  end

  defp pick(r, pool), do: Enum.at(pool, r.(length(pool)))

  test "valid resource, every garbage type in the matrix is typed" do
    for type <- @types do
      result = Charts.render(@resource, type)

      assert match?({:ok, s} when is_binary(s), result) or
               match?({:error, m} when is_map(m), result),
             "render(#{inspect(type)}) raised off-contract"
    end
  end

  test "every garbage resource term, with random valid and invalid types, is typed" do
    r = rng()

    for term <- @garbage do
      type = pick(r, @types)
      result = Charts.render(term, type)

      assert match?({:error, m} when is_map(m), result),
             "render(#{inspect(term)}, #{inspect(type)}) was not a typed refusal"
    end
  end

  test "random non-resource atoms are typed refusals for both arity paths" do
    atoms =
      for i <- 1..100 do
        String.to_atom("fuzz_charts_#{i}_#{:rand.uniform(1000)}")
      end

    for a <- atoms do
      for type <- [:state, :flow] do
        result = Charts.render(a, type)

        assert match?({:error, m} when is_map(m), result),
               "atom #{inspect(a)} raised: #{inspect(result)}"

        assert match?({:error, m} when is_map(m), Charts.render(a))
      end
    end
  end

  test "deterministic under seed replay" do
    run = fn ->
      r = rng()

      for _ <- 1..100 do
        Charts.render(pick(r, @garbage), pick(r, @types))
      end
    end

    assert run.() == run.()
  end
end
