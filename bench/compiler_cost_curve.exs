# BENCH lane: compiler cost curve vs plan size.
#
# Measures AshPPlan.Compiler.compile_spec/2 (the real compile path exercised by
# test/compiler_refusal_test.exs, pass-through NoopStep handlers) across plan
# sizes 10 / 100 / 1000 steps, in two shapes:
#
#   * linear chain  : step i depends on step i-1
#   * wide fan-out  : root -> N mid steps -> ceil(N/16) joins of 16 preds each
#                     (16 = the compiler's predecessor/terminal argument bound)
#
# Plus the duplicate-fence cost at 1000 steps:
#
#   * dup-free 1000-step plan (fence scans, finds nothing)
#   * 1000-step plan with 500 duplicate IRIs (fence refuses via :duplicate_steps)
#
# Run:
#   MIX_ENV=test MIX_BUILD_ROOT=_build-ch7 mix run bench/compiler_cost_curve.exs
#
# No new deps; in-script harness; garbage collected between samples via :erlang.garbage_collect.

defmodule Bench.NoopStep do
  use Reactor.Step

  @impl true
  def run(_arguments, _context, _options), do: {:ok, :noop}
end

defmodule Bench.CompilerCostCurve do
  @moduledoc false

  alias AshPPlan.Compiler

  @handler Bench.NoopStep

  def step(iri, predecessors \\ []) do
    %{iri: iri, label: iri, predecessors: predecessors, inputs: [], outputs: []}
  end

  def linear_chain(n) do
    iri = fn i -> "urn:bench:linear-#{n}-#{i}" end

    steps =
      Enum.map(1..n, fn i ->
        step(iri.(i), if(i == 1, do: [], else: [iri.(i - 1)]))
      end)

    %{iri: "urn:bench:linear-#{n}", steps: steps}
  end

  # 16-ary funnel tree: N leaf steps, then repeated levels that join 16
  # predecessors per step until at most 16 terminals remain (the compiler's
  # terminal and predecessor bounds). Reports the true step count, which is
  # slightly larger than n (n * 16/15 + slack).
  def wide_fanout(n) do
    level = Enum.map(1..n, &step("urn:bench:fan-#{n}-l0-#{&1}"))
    do_fanout(level, [], 0, n)
  end

  defp do_fanout(level, acc, _depth, _n) when length(level) <= 16 do
    %{iri: "urn:bench:fanout", steps: List.flatten(Enum.reverse(acc)) ++ level}
  end

  defp do_fanout(level, acc, depth, n) do
    next =
      level
      |> Enum.chunk_every(16)
      |> Enum.with_index(fn preds, j ->
        step("urn:bench:fan-#{n}-l#{depth + 1}-#{j}", Enum.map(preds, & &1.iri))
      end)

    do_fanout(next, [level | acc], depth + 1, n)
  end

  # A plan whose step list carries 500 duplicate IRIs — drives the
  # `ids -- Enum.uniq(ids)` duplicate fence into its worst case and refuses.
  def with_duplicates(n, dup_count) do
    base = linear_chain(n)

    dup_steps =
      if dup_count == 0,
        do: [],
        else: Enum.map(1..dup_count, fn i -> step("urn:bench:dup-#{n}-#{i}") end)

    dup_steps =
      Enum.map(dup_steps, fn s -> %{s | iri: Enum.at(base.steps, 0).iri} end)

    %{iri: "urn:bench:dup-#{n}", steps: base.steps ++ dup_steps}
  end

  def run_plan(name, plan, handlers, expect \\ :ok)

  def run_plan(name, plan, handlers, :ok) do
    sample(name, plan, handlers, fn
      {:ok, _reactor} -> true
      other -> raise "expected :ok compile, got #{inspect(elem(other, 0))}"
    end)
  end

  def run_plan(name, plan, handlers, :refuse) do
    sample(name, plan, handlers, fn
      {:error, %{reason: :duplicate_steps}} -> true
      other -> raise "expected :duplicate_steps refusal, got #{inspect(elem(other, 0))}"
    end)
  end

  defp sample(name, plan, handlers, check) do
    samples =
      for _ <- 1..5 do
        :erlang.garbage_collect()

        {us, result} = :timer.tc(fn -> Compiler.compile_spec(plan, handlers) end)
        true = check.(result)
        us
      end

    med = Enum.sort(samples) |> Enum.at(div(length(samples), 2))
    {name, med, Enum.min(samples), Enum.max(samples)}
  end

  def handlers(%{steps: steps}), do: Map.new(steps, &{&1.iri, @handler})

  def main do
    cases = [
      {"linear 10", linear_chain(10)},
      {"linear 100", linear_chain(100)},
      {"linear 1000", linear_chain(1000)},
      {"fanout 10", wide_fanout(10)},
      {"fanout 100", wide_fanout(100)},
      {"fanout 1000", wide_fanout(1000)}
    ]

    dup_cases = [
      {"dup-fence 1000 clean (0 dups)", with_duplicates(1000, 0)},
      {"dup-fence 1000 with 500 dups", with_duplicates(1000, 500), :refuse}
    ]

    rows =
      (cases ++ dup_cases)
      |> Enum.map(fn
        {name, plan, :refuse} ->
          IO.puts("running #{name} (#{length(plan.steps)} steps)")
          run_plan(name, plan, handlers(plan), :refuse)

        {name, plan} ->
          IO.puts("running #{name} (#{length(plan.steps)} steps)")
          run_plan(name, plan, handlers(plan))
      end)

    IO.puts("\n== AshPPlan.Compiler.compile_spec/2 cost curve (median of 5, microseconds) ==\n")
    IO.puts("| case | median us | min us | max us |")
    IO.puts("|---|---|---|---|")

    Enum.each(rows, fn {name, med, mn, mx} ->
      IO.puts("| #{name} | #{med} | #{mn} | #{mx} |")
    end)

    # Duplicate-fence refusal path must actually refuse.
    refused =
      Compiler.compile_spec(with_duplicates(1000, 500), handlers(with_duplicates(1000, 500)))

    case refused do
      {:error, %{reason: :duplicate_steps}} ->
        IO.puts("\nduplicate fence at 1000 steps: refused as expected (:duplicate_steps)")

      other ->
        IO.puts("\nUNEXPECTED dup result: #{inspect(other |> elem(0))}")
    end

    rows
  end
end

Bench.CompilerCostCurve.main()
