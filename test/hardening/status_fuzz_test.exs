defmodule AshPPlan.Reactor.Durable.StatusFuzzTest do
  @moduledoc """
  Fuzz court for `AshPPlan.Reactor.Durable.Status`.

  Every public predicate and `can?/2` is fed garbage — unknown atoms, non-atom terms
  (binaries, tuples, pids, nil, maps), and real-status pairs — and must answer with a
  boolean: typed refusals (`false`) never a raise. Property court: `can?/2` never
  admits a transition out of a terminal status, exhaustively over `all/0 x all/0`.

  The generated TLA model (`priv/tla/durable/transitions.exs`) is cross-checked against
  `can?/2` on every pair — the same differential pattern as
  `test/durable/tla_trace_test.exs` — extended over the fuzz inputs' typed shape:
  garbage terms must disagree with the model exactly where the model has no edge
  (i.e. `can?` must be false for every non-status term).
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Reactor.Durable.Status

  @all_statuses ~w(pending waiting polling unwinding cancelling unwind_blocked completed failed cancelled)a

  @model Code.eval_file(Path.expand("../../priv/tla/durable/transitions.exs", __DIR__))
         |> elem(0)

  @model_pairs MapSet.new(@model.transitions)

  # -- garbage corpus ----------------------------------------------------------

  @unknown_atoms ~w(pendng WAITING completedx nil POLLING unwind blocked)a ++
                   [:Pending, :"pending ", :pending__1, :completed0]

  defp garbage do
    [
      nil,
      "",
      "pending",
      "completed",
      <<0::8>>,
      "pending\0",
      {:pending, :waiting},
      {:pending},
      {},
      {1, 2, 3},
      [],
      [:pending],
      [pending: :waiting],
      %{},
      %{status: :pending},
      %{__struct__: Foo, status: :pending},
      0,
      1,
      -1,
      3.14,
      :infinity,
      self(),
      make_ref(),
      fn -> :ok end
    ]
  end

  defp terms, do: Status.all() ++ @unknown_atoms ++ garbage()

  defp assert_no_raise(label, fun) do
    fun.()
  rescue
    e ->
      flunk("Status.#{label} raised on #{inspect(label_axes(label))}: #{Exception.message(e)}")
  end

  defp label_axes({f, x}), do: "#{f}(#{inspect(x, limit: 3)})"
  defp label_axes({f, x, y}), do: "#{f}(#{inspect(x, limit: 3)}, #{inspect(y, limit: 3)})"

  describe "garbage never raises, always boolean" do
    test "unary predicates over every term" do
      for term <- terms() do
        assert_no_raise({:terminal?, term}, fn ->
          assert is_boolean(Status.terminal?(term))
        end)

        assert_no_raise({:parked?, term}, fn ->
          assert is_boolean(Status.parked?(term))
        end)

        assert_no_raise({:rolling_back?, term}, fn ->
          assert is_boolean(Status.rolling_back?(term))
        end)

        assert_no_raise({:cancellable?, term}, fn ->
          assert is_boolean(Status.cancellable?(term))
        end)
      end
    end

    test "can?/2 over every ordered pair of terms" do
      ts = terms()

      for a <- ts, b <- ts do
        assert_no_raise({:can?, a, b}, fn ->
          assert is_boolean(Status.can?(a, b))
        end)
      end
    end

    test "all/0 has no duplicates and covers the documented type" do
      all = Status.all()
      assert length(all) == length(Enum.uniq(all))
      assert Enum.sort(all) == Enum.sort(@all_statuses)
    end
  end

  describe "terminal absorption property" do
    test "can?/2 never admits out of a terminal status (exhaustive all x all)" do
      for from <- Status.all(), to <- Status.all(), Status.terminal?(from) do
        refute Status.can?(from, to),
               "terminal #{inspect(from)} admitted transition to #{inspect(to)}"
      end
    end

    test "terminal? agrees with the documented terminal set" do
      for s <- Status.all() do
        assert Status.terminal?(s) == s in ~w(completed failed cancelled)a
      end
    end
  end

  describe "TLA model differential" do
    test "can?/2 equals the generated transition set on every real pair" do
      for from <- Status.all(), to <- Status.all() do
        assert Status.can?(from, to) == MapSet.member?(@model_pairs, {from, to}),
               "can?(#{inspect(from)}, #{inspect(to)}) disagrees with transitions.exs"
      end
    end

    test "model statuses and terminal set match Status" do
      assert length(@model.transitions) == length(Enum.uniq(@model.transitions))
      assert Enum.sort(@model.statuses) == Enum.sort(Status.all())

      assert Enum.sort(@model.terminal) ==
               Enum.sort(Enum.filter(Status.all(), &Status.terminal?/1))
    end

    test "can?/2 is total-false over the fuzz typed shape" do
      # Garbage must land where the model has no edge: false. Unknown atoms, binaries,
      # tuples, pids, maps — none of them is a status, so every can? on them is false.
      for from <- terms(), to <- Status.all() ++ [hd(@unknown_atoms)] do
        expected = is_atom(from) and MapSet.member?(@model_pairs, {from, to})

        assert Status.can?(from, to) == expected,
               "can?(#{inspect(from, limit: 2)}, #{inspect(to)}) off-model"
      end
    end
  end

  describe "guard coherence" do
    test "parked?/rolling_back?/cancellable? partition cleanly on real statuses" do
      for s <- Status.all() do
        predicates = [
          Status.terminal?(s),
          Status.parked?(s),
          Status.rolling_back?(s),
          s == :pending,
          s == :unwind_blocked
        ]

        assert Enum.count(predicates, & &1) == 1,
               "#{inspect(s)} classified by #{Enum.count(predicates, & &1)} guards"
      end

      assert Status.parked?(:waiting) and Status.parked?(:polling)
      assert Status.rolling_back?(:unwinding) and Status.rolling_back?(:cancelling)

      assert Status.cancellable?(:pending) and Status.cancellable?(:waiting) and
               Status.cancellable?(:polling)

      refute Enum.any?(Status.all(), &(Status.cancellable?(&1) and Status.terminal?(&1)))
    end
  end
end
