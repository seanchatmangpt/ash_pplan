defmodule AshPPlan.Courts.PackRuntimeOverlayCourtTest do
  @moduledoc """
  Consumer court for `priv/ggen/ash-pplan-runtime-overlay` (the consumer
  overlay graph for the vendored ash-runtime-integration-contract-pack).

  COVERAGE NOTE (honest accounting): the overlay's 10 gates are vendored-copied
  into `priv/ggen/semantic-gate-witness/gates/` (06-receipt, 08-refusal) and
  exercised by the witness court
  (`test/courts/pack_gate_witness_court_test.exs`), and 06-receipt's mutation
  is exercised by `test/courts/pack_gate_mutation_court_test.exs`. That
  coverage proves the gates REFUSE on fail witnesses; it does NOT prove the
  gates fire against the overlay's own ontology, nor that render/determinism
  invariants hold. This court adds:

    1. GATES — all 10 gates run read-only via the native oxigraph engine
       (`GgenIgniter.Query.Oxigraph.run/2`) against the overlay ontology
       alone (the graph the consumer sync actually reads). Exact row counts
       asserted per gate, including the gates' POLARITY: 4 negative gates
       (`FILTER NOT EXISTS` missing-term detectors — 0 rows = pass) and
       6 positive gates (1 / 1 / 1 / 1 / 1 / 2 rows).
    2. ANTI-VACUITY — two mutations on a tmp copy of the overlay graph:
       (a) stripping one rt:SagaCompensation individual drops
       140-saga-compensation 2 -> 1 row, and (b) stripping a core vocabulary
       term's type triple flips negative gate 01-core-vocabulary 0 -> 1 row
       (a negative gate that never fires is itself refused).

  The overlay's templates are rendered by its driver
  (`bin/manufacture-runtime-contract`), not by ggen_igniter.sync frontmatter,
  so this court does not re-render them — render coverage for the runtime
  contract lives with the driver and the witness court. Select-only court:
  no DO authority.
  """

  use ExUnit.Case, async: false

  @repo Path.expand("../..", __DIR__)
  @pack "priv/ggen/ash-pplan-runtime-overlay"

  # Gate polarity: negative gates are FILTER NOT EXISTS missing-term detectors
  # (0 rows = pass); positive gates fire on real rows.
  @negative_gates [
    "gates/01-core-vocabulary.rq",
    "gates/02-runtime-shape-vocabulary.rq",
    "gates/03-provenance-root.rq",
    "gates/04-saga-compensation-gate.rq"
  ]

  @positive_gates [
    {"gates/01-exact-subject.rq", 1},
    {"gates/02-authority-policy.rq", 1},
    {"gates/06-receipt.rq", 1},
    {"gates/07-replay.rq", 1},
    {"gates/08-refusal.rq", 1},
    {"gates/140-saga-compensation.rq", 2}
  ]

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp scratch(name) do
    dir =
      Path.join(@repo, "tmp/court-runtime-overlay-#{name}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp overlay_graph do
    RDF.Turtle.read_file!(Path.join([@repo, @pack, "ontology.ttl"]))
  end

  defp gate_rows(graph, gate_rel, pack_dir \\ nil) do
    path =
      if pack_dir, do: Path.join(pack_dir, gate_rel), else: Path.join([@repo, @pack, gate_rel])

    query = File.read!(path)
    length(GgenIgniter.Query.Oxigraph.run(graph, query))
  end

  # ---------------------------------------------------------------------------
  # Court 1: gates (read-only, exact row counts per polarity)
  # ---------------------------------------------------------------------------

  test "gates: negative gates return 0 rows (nothing missing) via oxigraph" do
    graph = overlay_graph()

    for gate <- @negative_gates do
      rows = gate_rows(graph, gate)
      assert rows == 0, "negative gate #{gate} fired: expected 0 rows (pass), got #{rows}"
    end
  end

  test "gates: positive gates fire their exact row counts via oxigraph" do
    graph = overlay_graph()

    for {gate, expected} <- @positive_gates do
      rows = gate_rows(graph, gate)
      assert rows == expected, "gate #{gate}: expected #{expected} rows, got #{rows}"
    end
  end

  test "gates: the overlay ships exactly 10 gate files, all exercised" do
    on_disk =
      (@negative_gates ++ Enum.map(@positive_gates, fn {g, _} -> g end)) |> Enum.sort()

    assert length(on_disk) == 10

    disk_files =
      Path.wildcard(Path.join([@repo, @pack, "gates", "*.rq"]))
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    assert Enum.map(on_disk, &Path.basename/1) == disk_files,
           "court's gate list does not match the pack's gates directory"
  end

  # ---------------------------------------------------------------------------
  # Court 2: anti-vacuity (tmp copy of the overlay only)
  # ---------------------------------------------------------------------------

  test "anti-vacuity: stripping one SagaCompensation individual drops gate 140 from 2 to 1 rows" do
    corrupt = scratch("mutation-saga")
    corrupt_pack = Path.join(corrupt, "pack")
    File.cp_r!(Path.join(@repo, @pack), corrupt_pack)

    ontology_path = Path.join(corrupt_pack, "ontology.ttl")
    ttl = File.read!(ontology_path)
    needle = "rt:saga-comp-poll a rt:SagaCompensation ;"

    assert ttl =~ needle, "corruption target triple not found in overlay ontology"

    corrupted =
      String.replace(ttl, needle, "rt:saga-comp-poll a rt:NotASagaCompensation ;", count: 1)

    assert corrupted != ttl, "corruption changed nothing"
    File.write!(ontology_path, corrupted)

    graph = RDF.Turtle.read_file!(ontology_path)

    assert 1 = gate_rows(graph, "gates/140-saga-compensation.rq", corrupt_pack),
           "gate 140 did not see the corruption (vacuous)"
  end

  test "anti-vacuity: stripping a core vocabulary type flips negative gate 01 to 1 row" do
    corrupt = scratch("mutation-vocab")
    corrupt_pack = Path.join(corrupt, "pack")
    File.cp_r!(Path.join(@repo, @pack), corrupt_pack)

    ontology_path = Path.join(corrupt_pack, "ontology.ttl")
    ttl = File.read!(ontology_path)
    needle = "rt:Receipt a prov:Entity ."

    assert ttl =~ needle, "corruption target triple not found in overlay ontology"

    corrupted = String.replace(ttl, needle, "rt:Receipt a prov:NotAnEntity .", count: 1)
    assert corrupted != ttl, "corruption changed nothing"
    File.write!(ontology_path, corrupted)

    graph = RDF.Turtle.read_file!(ontology_path)
    rows = gate_rows(graph, "gates/01-core-vocabulary.rq", corrupt_pack)

    assert rows == 1,
           "negative gate 01-core-vocabulary did not see the missing vocabulary term (vacuous)"
  end
end
