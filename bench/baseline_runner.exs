# Repeated-run harness for bench/claims_bench.exs.
#
# Usage (plain elixir, no mix needed for the parent; each run is a fresh
# `mix run` child so VM state never carries between runs):
#
#     elixir bench/baseline_runner.exs [N] [script] [out.json]
#
# Defaults: N=5, script=bench/claims_bench.exs, out=bench/claims_raw.json.
# Run from the repo root (/Users/sac/ash_pplan).
#
# Each child's stdout table rows ("Component | Metric | Claim | MEASURED |
# Verdict") are parsed into numbers. The JSON holds, per metric, the per-run
# values plus min/median/max, and the per-run exit status. A run that exits
# non-zero is recorded and excluded from stats (never silently dropped).

defmodule Bench.BaselineRunner do
  @schema "ash_pplan/baseline-runner/1"

  def main(argv) do
    {n, script, out} = parse_args(argv)

    runs =
      for i <- 1..n do
        IO.puts(:stderr, "baseline_runner: run #{i}/#{n} #{script}")
        run_once(script, i)
      end

    ok = Enum.filter(runs, &(&1.exit == 0))
    metrics = aggregate(ok)

    doc = %{
      "schema" => @schema,
      "script" => script,
      "requested_runs" => n,
      "ok_runs" => length(ok),
      "runs" => Enum.map(runs, &%{"run" => &1.run, "exit" => &1.exit, "rows" => length(&1.rows)}),
      "metrics" => metrics
    }

    File.write!(out, encode(doc) <> "\n")
    IO.puts("baseline_runner: wrote #{out} (#{length(ok)}/#{n} runs ok, #{map_size(metrics)} metrics)")
    if ok == [], do: System.halt(1)
  end

  defp parse_args(argv) do
    n = case argv do [a | _] -> String.to_integer(a); _ -> 5 end
    script = Enum.at(argv, 1, "bench/claims_bench.exs")
    out = Enum.at(argv, 2, "bench/claims_raw.json")
    {max(n, 1), script, out}
  end

  defp run_once(script, i) do
    {out, status} =
      System.cmd("mix", ["run", script],
        env: [{"MIX_BUILD_ROOT", "_build-bench"}, {"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    %{run: i, exit: status, rows: if(status == 0, do: parse_rows(out), else: [])}
  end

  # Row: "RingBuffer.push solo | p50 (us) | < 10 | 0.00 | MET"
  defp parse_rows(text) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.split(line, " | ") do
        [comp, metric, _claim, measured, _verdict] ->
          case Float.parse(String.trim(measured)) do
            {v, _rest} -> [{String.trim(comp) <> " :: " <> String.trim(metric), v}]
            :error -> []
          end

        _ ->
          []
      end
    end)
  end

  defp aggregate(ok_runs) do
    ok_runs
    |> Enum.flat_map(& &1.rows)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {key, values} ->
      sorted = Enum.sort(values)

      {key,
       %{
         "values" => values,
         "min" => List.first(sorted),
         "median" => median(sorted),
         "max" => List.last(sorted)
       }}
    end)
  end

  defp median(sorted) do
    len = length(sorted)
    mid = div(len, 2)

    if rem(len, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  # Minimal deterministic JSON encoder (keys sorted) so the parent needs no deps.
  defp encode(map) when is_map(map) do
    body =
      map
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map_join(",", fn {k, v} -> encode(to_string(k)) <> ":" <> encode(v) end)

    "{" <> body <> "}"
  end

  defp encode(list) when is_list(list), do: "[" <> Enum.map_join(list, ",", &encode/1) <> "]"
  defp encode(s) when is_binary(s), do: "\"" <> escape(s) <> "\""
  defp encode(n) when is_integer(n), do: Integer.to_string(n)
  defp encode(f) when is_float(f), do: :erlang.float_to_binary(f, [:short])
  defp encode(nil), do: "null"
  defp encode(b) when is_boolean(b), do: to_string(b)

  defp escape(s), do: s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
end

Bench.BaselineRunner.main(System.argv())
