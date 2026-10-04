# Cross-contract courts harness for the ash-runtime-integration-contract-pack
# adoption (ECO-SAGA-COMPENSATE). First-ever consumer of the pack's
# cross-contract-courts.toml (86 zero-row falsifier courts) + its four admission
# gates, the latter run against the consumer overlay ontology. Anti-vacuity is
# built in:
#
#   * negative-fixture leg — every leak individual in the pack's
#     cross-contract-negative.ttl (authorityLeak, retryLeak, tenantCacheLeak,
#     apiLeak, reactorLeak) must be caught by at least one court, else the
#     court set carries no bits and the harness FAILS;
#   * gate-04 mutation leg — gate 04 (saga-compensation completeness) must pass
#     on the overlay ontology and must FAIL on an in-memory mutation of it
#     (the dispatch row's rt:effect value emptied), else the gate is vacuous
#     and the harness FAILS.
#
# Run via bin/runtime-contract-courts (mix run, same oxigraph engine family as
# the sync's --engine oxigraph; sparql/rdf are the already-locked ggen_igniter
# transitive deps). Exit 0 = green; exit 1 = named violations; exit 2 = setup
# refusal (pin moved, missing files).
#
#   bin/runtime-contract-courts                 # all legs
#   bin/runtime-contract-courts --fixture PATH  # one zero-row court run over PATH

# Re-pin receipt 2026-10-04: marketplace moved 5214eb0e -> 503af6c2 during the
# adoption; the pack's vendored surfaces are byte-identical across the move
# (witnessed by the sync's patched-set equality + regeneration idempotency),
# so the pin moves with the lock, not the bytes.
pin = "503af6c27cef7838dcd82755ab2fe6a44f9eb6a2"
market = System.get_env("RTI_MARKETPLACE") || Path.expand("~/ggen-marketplace")
pack = Path.join(market, "packs/ash-runtime-integration-contract-pack")
overlay = Path.expand("priv/ggen/ash-pplan-runtime-overlay", File.cwd!())

# ---- pin gate: read marketplace HEAD straight from .git (no git subprocess).
{head, _} =
  case File.read(Path.join(market, ".git/HEAD")) do
    {:ok, "ref: " <> ref} ->
      ref = String.trim(ref)

      case File.read(Path.join([market, ".git", ref])) do
        {:ok, sha} ->
          {String.trim(sha), ref}

        _ ->
          packed = Path.join([market, ".git", "packed-refs"])

          body =
            case File.read(packed) do
              {:ok, b} -> b
              _ -> ""
            end

          sha =
            body
            |> String.split("\n")
            |> Enum.find_value(fn line ->
              case String.split(String.trim(line)) do
                [sha, ^ref] -> sha
                _ -> nil
              end
            end)

          {sha, ref}
      end

    {:ok, detached} ->
      {String.trim(detached), "HEAD"}

    _ ->
      {nil, nil}
  end

unless head do
  IO.puts(:stderr, "courts: could not resolve marketplace HEAD under #{market}")
  System.halt(2)
end

if head != pin and System.get_env("RTI_ALLOW_MOVED_MARKETPLACE") != "1" do
  IO.puts(:stderr, "courts: marketplace HEAD #{head} != pinned #{pin}; refusing (RTI_ALLOW_MOVED_MARKETPLACE=1 overrides)")
  System.halt(2)
end

# ---- fixtures + courts manifest --------------------------------------------
args = OptionParser.parse(System.argv(), strict: [fixture: :string]) |> elem(0)
fixture_path = args[:fixture] || Path.join(pack, "tests/cross-contract-positive.ttl")
courts_toml_path = Path.join(pack, "cross-contract-courts.toml")
overlay_ontology = Path.join(overlay, "ontology.ttl")

for f <- [fixture_path, courts_toml_path, overlay_ontology] do
  unless File.regular?(f) do
    IO.puts(:stderr, "courts: missing required file #{f}")
    System.halt(2)
  end
end

court_paths = Toml.decode!(File.read!(courts_toml_path)) |> Map.fetch!("courts")
IO.puts("courts: pin #{String.slice(head, 0, 7)} | #{length(court_paths)} cross-contract courts")

engine = fn graph, text -> GgenIgniter.Query.Oxigraph.run(graph, text) end

court_texts = Map.new(court_paths, fn rel -> {rel, File.read!(Path.join(pack, rel))} end)

run_all_detailed = fn graph, court_texts ->
  Enum.flat_map(court_texts, fn {rel, text} ->
    case engine.(graph, text) do
      [] -> []
      rows -> [{rel, length(rows), rows}]
    end
  end)
end

fixture_graph = RDF.Turtle.read_file!(fixture_path)
positive_failures = run_all_detailed.(fixture_graph, court_texts)

# ---- --fixture mode: single zero-row court run over PATH --------------------
if args[:fixture] do
  if positive_failures == [] do
    IO.puts("courts: zero-row over #{fixture_path} (#{length(court_paths)} courts)")
    System.halt(0)
  else
    Enum.each(positive_failures, fn {rel, n, rows} ->
      IO.puts(:stderr, "courts: FAIL #{rel}: #{n} unsafe row(s) over #{fixture_path}")
      IO.puts(:stderr, "courts:   rows: #{inspect(rows, limit: 10, printable_limit: 200)}")
    end)

    System.halt(1)
  end
end

# ---- full mode ---------------------------------------------------------------
# The four pack admission gates over the OVERLAY ontology. gates/140-saga-
# compensation.rq is the --for-each driver (returns the two saga rows by
# design), not a gate — excluded here.
gate_files = [
  "gates/01-core-vocabulary.rq",
  "gates/02-runtime-shape-vocabulary.rq",
  "gates/03-provenance-root.rq",
  "gates/04-saga-compensation-gate.rq"
]

overlay_graph = RDF.Turtle.read_file!(overlay_ontology)

gate_failures =
  Enum.flat_map(gate_files, fn rel ->
    case engine.(overlay_graph, File.read!(Path.join(overlay, rel))) do
      [] -> []
      rows -> [{rel, length(rows)}]
    end
  end)

# ---- anti-vacuity leg 1: every documented leak must be caught ---------------
neg_graph = RDF.Turtle.read_file!(Path.join(pack, "tests/cross-contract-negative.ttl"))
leaks = ["authorityLeak", "retryLeak", "tenantCacheLeak", "apiLeak", "reactorLeak"]

uncaught =
  Enum.filter(leaks, fn leak ->
    not Enum.any?(court_texts, fn {_rel, text} ->
      engine.(neg_graph, text)
      |> Enum.any?(fn row ->
        row |> Map.values() |> Enum.any?(fn v -> is_binary(v) and String.contains?(v, leak) end)
      end)
    end)
  end)

# ---- anti-vacuity leg 2: gate-04 in-memory mutation --------------------------
gate04_text = File.read!(Path.join(overlay, "gates/04-saga-compensation-gate.rq"))
overlay_text = File.read!(overlay_ontology)

effect_value =
  "starts a child run via Engine.start/3 (a real durable-ledger side effect); the step has undo/4 but no compensate/4"

mutated_text = String.replace(overlay_text, effect_value, "")

mutation =
  if mutated_text == overlay_text do
    {:error, :mutation_did_not_apply}
  else
    case mutated_text |> RDF.Turtle.read_string!() |> engine.(gate04_text) do
      [] -> {:error, :gate04_vacuous}
      rows -> {:ok, length(rows)}
    end
  end

# ---- report -------------------------------------------------------------------
failed = []

failed =
  case positive_failures do
    [] ->
      IO.puts("courts: positive fixture: #{length(court_paths)} courts zero-row")
      failed

    _ ->
      Enum.each(positive_failures, fn {rel, n} ->
        IO.puts(:stderr, "courts: FAIL #{rel}: #{n} unsafe row(s) over the POSITIVE fixture")
      end)

      failed ++ positive_failures
  end

failed =
  case gate_failures do
    [] ->
      IO.puts("courts: gates: 4 gates zero-row over the overlay ontology")
      failed

    _ ->
      Enum.each(gate_failures, fn {rel, n} ->
        IO.puts(:stderr, "courts: FAIL gate #{rel}: #{n} violation row(s)")
      end)

      failed ++ gate_failures
  end

failed =
  case uncaught do
    [] ->
      IO.puts("courts: anti-vacuity: all 5 documented leaks caught (#{Enum.join(leaks, ", ")})")
      failed

    _ ->
      IO.puts(:stderr, "courts: FAIL anti-vacuity: leaks NOT caught by any court: #{inspect(uncaught)}")
      failed ++ Enum.map(uncaught, &{:leak, &1})
  end

failed =
  case mutation do
    {:ok, n} ->
      IO.puts("courts: gate-04 mutation: caught (#{n} violation row(s) on the mutated graph)")
      failed

    {:error, :mutation_did_not_apply} ->
      IO.puts(:stderr, "courts: FAIL gate-04 mutation: the mutation did not apply (overlay ontology drifted)")
      failed ++ [{:gate04_mutation, :mutation_did_not_apply}]

    {:error, :gate04_vacuous} ->
      IO.puts(:stderr, "courts: FAIL gate-04 mutation: gate 04 passed the mutated ontology (vacuous)")
      failed ++ [{:gate04_mutation, :vacuous}]
  end

if failed == [] do
  IO.puts("courts: GREEN — #{length(court_paths)} cross-contract courts, 4 gates, 2 anti-vacuity legs witnessed")
  System.halt(0)
else
  IO.puts(:stderr, "courts: #{length(failed)} leg item(s) failed")
  System.halt(1)
end
