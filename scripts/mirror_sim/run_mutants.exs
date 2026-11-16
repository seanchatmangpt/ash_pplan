# Usage: MIX_ENV=test mix run scripts/mirror_sim/run_mutants.exs [--limit N] [--ids A,B] [--catalog core|runtime|all]
# Runs catalog mutants through AshPPlan.MirrorSim.Mutation (scratch copy of lib/, byte-exact restore).
# Prints one line per mutant and a final `MUTANTS killed=N survived=M` line; exits 1 on any :fail.
alias AshPPlan.MirrorSim.{Mutation, MutantsCore, MutantsRuntime}

{opts, _, _} =
  OptionParser.parse(System.argv(), strict: [limit: :integer, ids: :string, catalog: :string])

# Survivors of the first full run are killed by dedicated courts (id -> test file).
kill_courts =
  Map.new(
    for(
      id <-
        ~w(CMP-03-dangling-admitted CMP-19-unsupported-powl-shape-refused CMP-20-empty-iri-admitted),
      do: {id, "test/mirror_sim/kill_compiler_test.exs"}
    ) ++
      for(
        id <-
          ~w(STD-07-missing-dependency-tolerated STD-10-events-unsorted STD-11-seal-always-alive STD-15-ocel-digest-unprefixed STD-17-empty-observation-actuates STD-18-validated-rung-vacuous OBL-01-id-prefix-truncated OBL-03-verify-always-true OBL-04-malformed-verifies),
        do: {id, "test/mirror_sim/kill_standing_test.exs"}
      ) ++
      for(id <- ~w(SA-01 SA-02 SA-04 SA-10 SA-11), do: {id, "test/mirror_sim/kill_sa2a_test.exs"}) ++
      for(id <- ~w(PD-01 DS-05 DS-06 DS-08), do: {id, "test/mirror_sim/kill_durable_test.exs"}) ++
      for(
        id <- ~w(PR-01 PR-02 PR-03 PR-04 PW-01 PW-03 PW-04 PW-05 FO-06 RC-07),
        do: {id, "test/mirror_sim/kill_registry_powl_test.exs"}
      )
  )

cat = opts[:catalog] || "all"
ids = if opts[:ids], do: String.split(opts[:ids], ","), else: nil

mutants =
  if(cat in ["core", "all"], do: MutantsCore.catalog(), else: []) ++
    if cat in ["runtime", "all"], do: MutantsRuntime.catalog(), else: []

mutants = Enum.map(mutants, &%{&1 | court: Map.get(kill_courts, &1.id, &1.court)})
mutants = if ids, do: Enum.filter(mutants, &(&1.id in ids)), else: mutants
mutants = if opts[:limit], do: Enum.take(mutants, opts[:limit]), else: mutants

results =
  for m <- mutants do
    spec = %{m | file: String.replace_prefix(m.file, "lib/", "")}

    r =
      case Mutation.court_cmd(m.court) do
        {:ok, cmd} -> Mutation.run(spec, cmd)
        :error -> %{status: :skip, reason: :court_refused}
      end

    eq = Map.get(m, :equivalent) || Map.get(m, :expected_kill)

    IO.puts(
      "#{m.id} #{r.status} #{inspect(Map.get(r, :reason))} kill_kind=#{inspect(Map.get(r, :kill_kind))} expect=#{inspect(eq)} court=#{m.court}"
    )

    if r.status == :skip,
      do: IO.puts("  output: " <> String.slice(to_string(Map.get(r, :output, "")), -900, 900))

    Map.put(r, :id, m.id)
  end

k = Enum.count(results, &(&1.status == :killed))
s = Enum.count(results, &(&1.status == :survived))
sk = Enum.count(results, &(&1.status == :skip))
f = Enum.count(results, &(&1.status == :fail))
IO.puts("MUTANTS killed=#{k} survived=#{s}")
IO.puts("skipped=#{sk} failed=#{f} total=#{length(results)}")
if f > 0, do: System.halt(1)
