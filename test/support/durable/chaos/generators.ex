defmodule AshPPlan.Test.Chaos.Generators do
  @moduledoc """
  Hand-written StreamData generators for chaos scenarios. A scenario is plain data:

      %{tasks: [%{kind: :count | :await | :poll, deps: [index], k: poll_checks}], ops: [op]}

  with ops `:attempt`, `{:kill, phase, nth}`, `{:signal, task_index}` (an early, late or duplicate
  delivery depending on when it lands), `{:advance, ms}` (clock jump, may cross the claim lease)
  and `:cancel`. The workflow is a DAG of 1-8 tasks; deps only point at earlier indexes.
  """
  use ExUnitProperties
  import StreamData

  @phases [:after_claim, :after_record, :after_park, :before_release_claim]

  @spec scenario() :: StreamData.t(map())
  def scenario do
    bind(integer(1..8), fn n ->
      bind(tasks(n), fn tasks ->
        map(list_of(op(tasks), max_length: 10), fn ops -> %{tasks: tasks, ops: ops} end)
      end)
    end)
  end

  @spec tasks(pos_integer()) :: StreamData.t([map()])
  def tasks(n) do
    0..(n - 1)
    |> Enum.map(fn i ->
      gen all(
            kind <-
              frequency([{4, constant(:count)}, {2, constant(:await)}, {1, constant(:poll)}]),
            picks <- list_of(boolean(), length: i),
            k <- integer(0..3)
          ) do
        deps = for {true, d} <- Enum.zip(picks, 0..(i - 1)//1), do: d
        %{kind: kind, deps: deps, k: k}
      end
    end)
    |> fixed_list()
    |> map(&single_sink/1)
  end

  # Known defect (lane m3 unresolved): `Subject.observe/3` crashes on the multi-terminal
  # `{:ash_pplan, :return}` collector step, so workflows keep exactly one terminal: the last task
  # absorbs every task nothing depends on.
  defp single_sink(tasks) do
    last = length(tasks) - 1
    used = tasks |> Enum.flat_map(& &1.deps) |> MapSet.new()
    sinks = for i <- 0..(last - 1)//1, not MapSet.member?(used, i), do: i
    List.update_at(tasks, last, &%{&1 | deps: Enum.uniq(&1.deps ++ sinks)})
  end

  defp op(tasks) do
    awaits = for {%{kind: :await}, i} <- Enum.with_index(tasks), do: i

    base = [
      {4, constant(:attempt)},
      {3, map({member_of(@phases), integer(1..3)}, fn {p, n} -> {:kill, p, n} end)},
      {3, map(integer(1..120_000), &{:advance, &1})},
      {1, constant(:cancel)}
    ]

    signals = if awaits == [], do: [], else: [{4, map(member_of(awaits), &{:signal, &1})}]
    frequency(base ++ signals)
  end
end
