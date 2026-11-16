# Mirror-sim coverage gate. Run: MIX_ENV=test mix run scripts/mirror_sim/coverage.exs
# Exits 1 on any MISSING cell, phantom mirror surface, or invalid KD row.
alias AshPPlan.MirrorSim.Coverage

r = Coverage.report()

IO.puts(
  "mirror-sim coverage: total=#{r.total} pass=#{r.pass} divergence=#{r.divergence} missing=#{r.missing}"
)

for c <- r.divergence_cells, do: IO.puts("  DIVERGENCE #{c.surface} (#{c.kd})")
for m <- r.missing_cells, do: IO.puts("  MISSING #{m}")
for p <- r.phantoms, do: IO.puts("  PHANTOM #{p}")
for k <- r.invalid_kd_rows, do: IO.puts("  INVALID-KD #{k}")
for k <- r.stale_kd_rows, do: IO.puts("  STALE-KD #{k}")

if r.ok and r.invalid_kd_rows == [] do
  IO.puts("COVERAGE PASS")
else
  IO.puts("COVERAGE FAIL")
  System.halt(1)
end
