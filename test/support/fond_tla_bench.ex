defmodule AshPPlan.Test.FONDTLABench do
  @moduledoc """
  Deterministic timing harness for the FOND -> TLA+ projection.

  Two scalable domain families, both with a known verdict:

    * `:retry_chain` — `c<i> --step--> {c<i>, c<i+1>}`, goal `c<n>`: every state
      retries, so strong refuses and strong-cyclic admits.
    * `:fanout` — `root --split--> {w1..wn}`, `w<i> --finish--> {goal}`: strong
      and strong-cyclic both admit; stresses the validator's frontier.

  `measure/3` returns, for `render` (`FOND.to_tla/4`), `reader`
  (`TLAReader.check!/1` on the rendered text) and `validate`
  (`FOND.validate_policy/4`): the median wall-clock microseconds of `runs`
  repetitions after one warm-up (`*_us`, host-load sensitive, recorded only),
  and the BEAM reductions of one run in a fresh process (`*_reductions`,
  deterministic for a given OTP release and input, used for the regression
  bound), plus the rendered byte size and both verdicts.
  Used by `bench/fond_tla_bench.exs` (numbers) and
  `test/fond_tla_bench_test.exs` (regression bound).
  """

  alias AshPPlan.FOND
  alias AshPPlan.Test.TLAReader

  def domain(:retry_chain, n) do
    states = for i <- 0..n, do: :"c#{i}"

    transitions =
      states
      |> Enum.chunk_every(2, 1, :discard)
      |> Map.new(fn [a, b] -> {a, %{step: [a, b]}} end)
      |> Map.put(:"c#{n}", %{})

    policy = for i <- 0..(n - 1), into: %{}, do: {:"c#{i}", :step}
    {:ok, domain} = FOND.new(transitions, [:"c#{n}"])
    {domain, policy, :c0}
  end

  def domain(:fanout, n) do
    workers = for i <- 1..n, do: {:w, i}

    transitions =
      workers
      |> Map.new(&{&1, %{finish: [:goal]}})
      |> Map.put(:root, %{split: workers})
      |> Map.put(:goal, %{})

    policy = workers |> Map.new(&{&1, :finish}) |> Map.put(:root, :split)
    {:ok, domain} = FOND.new(transitions, [:goal])
    {domain, policy, :root}
  end

  def measure(family, n, mode, runs \\ 5) do
    {domain, policy, initial} = domain(family, n)
    {:ok, rendered} = FOND.to_tla(domain, policy, initial, mode)

    validate = fn -> FOND.validate_policy(domain, policy, initial, mode) end
    render = fn -> FOND.to_tla(domain, policy, initial, mode) end
    reader = fn -> TLAReader.check!(rendered) end

    verdict =
      case validate.() do
        {:ok, _} -> :admitted
        {:error, _} -> :refused
      end

    %{
      family: family,
      n: n,
      mode: mode,
      states: MapSet.size(domain.states),
      module_bytes: byte_size(rendered.module),
      verdict: verdict,
      reader_verdict: reader.().verdict,
      render_us: median_us(render, runs),
      reader_us: median_us(reader, runs),
      validate_us: median_us(validate, runs),
      render_reductions: reductions(render),
      reader_reductions: reductions(reader),
      validate_reductions: reductions(validate)
    }
  end

  @doc "Reductions spent by `fun` in a fresh process (no inherited heap or mailbox)."
  def reductions(fun) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:reductions, before} = Process.info(self(), :reductions)
        _ = fun.()
        {:reductions, after_run} = Process.info(self(), :reductions)
        send(parent, {:bench_reductions, self(), after_run - before})
      end)

    receive do
      {:bench_reductions, ^pid, count} ->
        Process.demonitor(ref, [:flush])
        count

      {:DOWN, ^ref, :process, ^pid, reason} ->
        raise "bench process died: #{inspect(reason)}"
    end
  end

  defp median_us(fun, runs) do
    _warm = fun.()

    1..runs
    |> Enum.map(fn _ -> fun |> :timer.tc() |> elem(0) end)
    |> Enum.sort()
    |> Enum.at(div(runs, 2))
  end
end
