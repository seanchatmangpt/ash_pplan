# Deterministic timing run for the FOND -> TLA+ projection.
#
#   MIX_ENV=test mix run bench/fond_tla_bench.exs [out.json]
#
# Prints one JSON document (median microseconds per operation) and, when a
# path is given, writes it there. The committed regression bound lives in
# test/fond_tla_bench_test.exs; this script produces the numbers recorded in
# the bench receipt.
alias AshPPlan.Test.FONDTLABench

rows =
  for family <- [:retry_chain, :fanout],
      n <- [100, 1_000, 5_000],
      mode <- [:strong, :strong_cyclic] do
    FONDTLABench.measure(family, n, mode, 5)
  end

doc = %{
  schema: "ash_pplan/fond-tla-bench/1",
  otp: System.otp_release(),
  elixir: System.version(),
  system: :erlang.system_info(:system_architecture) |> to_string(),
  schedulers: System.schedulers_online(),
  rows: rows
}

json = JSON.encode!(doc)
IO.puts(json)

case System.argv() do
  [path] -> File.write!(path, json)
  _ -> :ok
end
