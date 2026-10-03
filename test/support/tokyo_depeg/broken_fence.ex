defmodule AshPPlan.Test.TokyoDepeg.BrokenFence do
  @moduledoc """
  The fencing mutant: a REAL broken implementation (Chicago, no mocks) of the
  duplicate-order fence — a naive check-then-act ETS dedup with NO compare-and-swap.
  The check-then-act window is deliberately widened by a sleep so the 200-task
  barrage interleaves deterministically and several "executors" get through.
  It implements the same behaviour contract as the production Engine-based
  fencing subject in the court: `run_barrage/2` -> `:pass` iff the duplicate
  order executed exactly once across the barrage.
  """

  @doc """
  Barrage of `n` concurrent duplicate orders for `order_id` against a naive
  non-atomic dedup table. Returns `{:fail, executed}` (executed > 1 expected)
  or, in the astronomically unlikely event the race does not interleave,
  `:pass` — which itself fails the anti-vacuity assertion.
  """
  def run_barrage(n, order_id, table \\ :broken_fence_dedup, mode \\ :check_then_act)

  def run_barrage(n, order_id, table, :check_then_act) do
    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set])
    else
      :ets.delete_all_objects(table)
    end

    tasks =
      Enum.map(1..n, fn i ->
        Task.async(fn ->
          # naive check-then-act: read, sleep, write — no atomic claim. The
          # sleep guarantees the barrage interleaves inside the window.
          if :ets.lookup(table, order_id) == [] do
            Process.sleep(:rand.uniform(10))
            :ets.insert(table, {order_id, self(), System.system_time()})
            execute_once(order_id, i)
            {:ok, :executor}
          else
            {:ok, :replay}
          end
        end)
      end)

    results = Task.await_many(tasks, 30_000)
    executed = Enum.count(results, &match?({:ok, :executor}, &1))

    if executed == 1, do: :pass, else: {:fail, executed}
  end

  # SECOND sabotage form — a different defect class, not a race: claim the
  # order FIRST (unconditional insert), then "execute". Every task executes,
  # so `executed == n` deterministically; no timing luck involved. This kills
  # the vacuous outcome where the check-then-act mutant happens to pass on a
  # quiet machine (`:pass` from the race window not interleaving).
  def run_barrage(n, order_id, table, :write_before_check) do
    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set])
    else
      :ets.delete_all_objects(table)
    end

    tasks =
      Enum.map(1..n, fn i ->
        Task.async(fn ->
          # inverted defect: act before check — the claim never fences anything.
          :ets.insert(table, {order_id, self(), System.system_time()})
          execute_once(order_id, i)
          {:ok, :executor}
        end)
      end)

    results = Task.await_many(tasks, 30_000)
    executed = Enum.count(results, &match?({:ok, :executor}, &1))

    if executed == 1, do: :pass, else: {:fail, executed}
  end

  defp execute_once(_order_id, _i), do: :ok
end
