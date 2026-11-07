defmodule AshPPlan.FOND.ReplayTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Replay

  test "same exact subject and seed manufacture the same replay identity" do
    {:ok, domain} = FOND.new(%{pending: %{go: [:pending, :done]}, done: %{}}, [:done])

    opts = [seed: {7, 11, 13}]

    assert {:ok, first} =
             Replay.build(domain, %{pending: :go}, :pending, :strong_cyclic, opts)

    assert {:ok, second} =
             Replay.build(domain, %{pending: :go}, :pending, :strong_cyclic, opts)

    assert Replay.fingerprint(first) == Replay.fingerprint(second)
    assert first.subject.id == second.subject.id
  end

  describe "hashable?/1 totality matrix" do
    defp domain do
      {:ok, d} = FOND.new(%{pending: %{go: [:pending, :done]}, done: %{}}, [:done])
      d
    end

    test "functions, pids, refs and ports are unhashable" do
      fun = fn :x -> :x end

      for term <- [fun, self(), make_ref()] do
        refute Replay.hashable?(term), "expected unhashable: #{inspect(term)}"
      end
    end

    test "containers carrying a hostile term at any depth are unhashable" do
      fun = fn :x -> :x end

      for term <- [
            [1, 2, fun],
            %{k: self()},
            {1, make_ref()},
            %{a: [1, %{b: {1, fn -> :boom end}}]}
          ] do
        refute Replay.hashable?(term)
      end
    end

    test "hashable terms answer true (atoms, numbers, binaries, 100k-key map)" do
      big_map = Map.new(1..100_000, fn i -> {:"key_#{i}", i} end)

      for term <- [:ok, 42, "bin", [], big_map, {1, %{a: [:x]}}] do
        assert Replay.hashable?(term)
      end
    end

    test "build/5 pre-flight refuses unhashable initial typed" do
      assert {:error, {:unhashable_term, :initial}} =
               Replay.build(domain(), %{pending: :go}, %{pending: self()}, :strong_cyclic)
    end

    test "build/5 pre-flight refuses unhashable seed typed" do
      assert {:error, {:unhashable_term, :seed}} =
               Replay.build(domain(), %{pending: :go}, :pending, :strong_cyclic,
                 seed: fn -> :boom end
               )
    end

    test "nil seed is not pre-flighted as seed" do
      assert {:ok, _bundle} = Replay.build(domain(), %{pending: :go}, :pending, :strong_cyclic)
    end
  end
end
