defmodule AshPPlan.FONDTLABenchTest do
  @moduledoc """
  Regression bound for the FOND -> TLA+ projection, measured with
  `AshPPlan.Test.FONDTLABench` (real renders, real reader, real validator).

  The bound is on BEAM reductions, not wall-clock: reductions are deterministic
  for a given OTP release and input, so the gate does not flake under host load
  (the v26.9.26 bench ran at load average ~190, where wall-clock medians moved
  by 10x between identical runs). Recorded on OTP 28 (bench receipt
  `bench-ash_pplan-6-*.json`): render ~1190 and reader ~1060 reductions per
  state on the 1000-state retry chain, both doubling within 1% when the domain
  doubles. Bounds: <= 3000 reductions per state and a doubling ratio <= 2.5,
  which admits OTP drift but refuses any quadratic regression (ratio ~4).
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Test.FONDTLABench

  @per_state 3_000
  @doubling 2.5

  for family <- [:retry_chain, :fanout], mode <- [:strong, :strong_cyclic] do
    test "render and reader stay linear: #{family} #{mode}" do
      small = FONDTLABench.measure(unquote(family), 500, unquote(mode), 1)
      large = FONDTLABench.measure(unquote(family), 1_000, unquote(mode), 1)

      for row <- [small, large] do
        assert row.verdict == row.reader_verdict, inspect(row)
        assert row.render_reductions <= @per_state * row.states, inspect(row)
        assert row.reader_reductions <= @per_state * row.states, inspect(row)
      end

      assert large.render_reductions / small.render_reductions <= @doubling,
             "render grew superlinearly: #{inspect({small, large})}"

      assert large.reader_reductions / small.reader_reductions <= @doubling,
             "reader grew superlinearly: #{inspect({small, large})}"
    end
  end

  test "known verdicts of the bench families" do
    assert %{verdict: :refused} = FONDTLABench.measure(:retry_chain, 50, :strong, 1)
    assert %{verdict: :admitted} = FONDTLABench.measure(:retry_chain, 50, :strong_cyclic, 1)
    assert %{verdict: :admitted} = FONDTLABench.measure(:fanout, 50, :strong, 1)
    assert %{verdict: :admitted} = FONDTLABench.measure(:fanout, 50, :strong_cyclic, 1)
  end

  test "the harness gate refuses a quadratic workload (anti-vacuity)" do
    linear = fn n -> FONDTLABench.reductions(fn -> Enum.sum(1..n) end) end
    quadratic = fn n -> FONDTLABench.reductions(fn -> for i <- 1..n, j <- 1..n, do: i * j end) end

    assert linear.(2_000) / linear.(1_000) <= @doubling
    refute quadratic.(400) / quadratic.(200) <= @doubling
  end
end
