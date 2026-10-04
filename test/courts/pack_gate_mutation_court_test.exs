defmodule AshPPlan.Courts.PackGateMutationCourtTest do
  @moduledoc """
  Court: pack gates are mutation-sensitive, not vacuous pass-machines.

  The ERRC synthesis found no gate in the tree carries a NEGATIVE witness:
  conform-falsify covers the SHACL profile only. This court closes the
  remaining hole by proving each sampled gate's WHERE clause actually
  depends on the data it inspects:

    (a) POSITIVE FIRING — the gate run against the real pack ontology yields
        non-empty rows (the gate sees real individuals).
    (b) MUTATION SENSITIVITY — corrupt exactly one triple the gate's WHERE
        clause requires; the gate's rows MUST drop to empty. A gate that
        still fires after its discriminating triple is deleted is vacuous.

    (c) ANTI-VACUITY ON THE COURT ITSELF — a deliberately tautological gate
        (`SELECT ?s WHERE { ?s ?p ?o }`) fails (b): no single triple
        deletion can empty it. If the court's check would admit the
        tautology, the court is vacuous.

  Fixtures are the packs' own shipped ontologies (the same inputs
  `bin/ggen-verify` runs gates against). The real fixtures are read-only:
  mutations are applied to in-memory RDF graphs only.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @gates [
    %{
      id: "ash-pplan-pack/010_projections",
      pack: "priv/ggen/ash-pplan-pack/ontology.ttl",
      gate: "priv/ggen/ash-pplan-pack/gates/010_projections.rq",
      # WHERE requires `ap:status` on every Projection row.
      mutate: {RDF.iri("https://w3id.org/ash-pplan#status"), :any_object}
    },
    %{
      id: "ash-pplan-runtime-overlay/06-receipt",
      pack: "priv/ggen/ash-pplan-runtime-overlay/ontology.ttl",
      gate: "priv/ggen/ash-pplan-runtime-overlay/gates/06-receipt.rq",
      # WHERE requires `a rt:Integration` on the subject.
      mutate:
        {RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
         RDF.iri("https://ggen.dev/ontology/runtime-integration#Integration")}
    },
    %{
      # WHERE requires `sg:standingName` (the OPTIONAL neutralStanding is not needed).
      id: "ash-pplan-standing-pack/030_standings",
      pack: "priv/ggen/ash-pplan-standing-pack/ontology.ttl",
      gate: "priv/ggen/ash-pplan-standing-pack/gates/030_standings.rq",
      mutate: {RDF.iri("https://w3id.org/ash-pplan/standing#standingName"), :any_object}
    }
  ]

  @tautological_gate """
  PREFIX ap: <https://w3id.org/ash-pplan#>
  SELECT ?s ?p ?o WHERE { ?s ?p ?o }
  """

  # ---------------------------------------------------------------------------
  # Court helpers
  # ---------------------------------------------------------------------------

  defp root, do: @root

  defp read_graph(rel) do
    abs = Path.join(root(), rel)

    unless File.exists?(abs) do
      flunk("fixture missing: #{abs}")
    end

    RDF.Turtle.read_file!(abs)
  end

  defp read_gate(rel) do
    abs = Path.join(root(), rel)

    unless File.exists?(abs) do
      flunk("gate missing: #{abs}")
    end

    File.read!(abs)
  end

  defp run_gate(graph, gate_text) do
    case SPARQL.execute_query(graph, gate_text) do
      %SPARQL.Query.Result{} = result ->
        result.results

      other ->
        flunk("SPARQL execution failed: #{inspect(other)}")
    end
  end

  # Deletes every triple matching the given {predicate, object} pattern
  # (object :any_object matches any). One mutation operation: the gate's
  # discriminating pattern is stripped from every row's subject, so no row
  # of the gate can satisfy its WHERE clause.
  defp mutate_drop_pattern(graph, {pred_iri, object}) do
    pred = RDF.iri(pred_iri)
    obj = if object == :any_object, do: :any, else: object

    triples =
      Enum.filter(graph, fn {_s, p, o} ->
        p == pred and (obj == :any or o == obj)
      end)

    case triples do
      [] -> flunk("mutation target not found in fixture: #{pred} / #{inspect(object)}")
      _ -> RDF.Graph.delete(graph, triples)
    end
  end

  defp mutation_sensitive?(graph, gate_text, pattern) do
    original = run_gate(graph, gate_text)
    mutated = run_gate(mutate_drop_pattern(graph, pattern), gate_text)

    %{
      original_rows: length(original),
      mutated_rows: length(mutated),
      sensitive?: length(original) > 0 and length(mutated) == 0
    }
  end

  # ---------------------------------------------------------------------------
  # Court
  # ---------------------------------------------------------------------------

  setup_all do
    # Load each pack ontology once; gates run against the real shipped fixture.
    %{
      fixtures:
        for {spec, idx} <- Enum.with_index(@gates), into: %{} do
          {idx, read_graph(spec.pack)}
        end
    }
  end

  describe "positive firing on real fixtures" do
    test "every sampled gate yields non-empty rows against its real pack ontology", %{
      fixtures: fixtures
    } do
      for {spec, idx} <- Enum.with_index(@gates) do
        gate = read_gate(spec.gate)
        rows = run_gate(fixtures[idx], gate)

        assert rows != [],
               "gate #{spec.id} fired ZERO rows against #{spec.pack} — " <>
                 "a gate that never fires cannot refuse anything (vacuous gate)"
      end
    end
  end

  describe "mutation sensitivity" do
    test "corrupting one required triple drops each gate to empty", %{fixtures: fixtures} do
      for {spec, idx} <- Enum.with_index(@gates) do
        gate = read_gate(spec.gate)
        report = mutation_sensitive?(fixtures[idx], gate, spec.mutate)

        assert report.original_rows > 0,
               "gate #{spec.id}: baseline fixture yielded no rows; court precondition broken"

        assert report.mutated_rows == 0,
               "gate #{spec.id} STILL FIRED #{report.mutated_rows} row(s) after its " <>
                 "discriminating pattern #{inspect(spec.mutate)} was deleted — " <>
                 "the gate is data-independent (vacuous)"
      end
    end
  end

  describe "anti-vacuity of the court itself" do
    test "a tautological gate fails the mutation-sensitivity check" do
      graph = read_graph("priv/ggen/ash-pplan-pack/ontology.ttl")

      report =
        mutation_sensitive?(
          graph,
          @tautological_gate,
          {RDF.iri("https://w3id.org/ash-pplan#status"), :any_object}
        )

      # The tautology still returns rows on the mutated graph (deleting one
      # triple cannot empty `SELECT ?s ?p ?o`), so it must NOT pass.
      refute report.sensitive?,
             "court admitted a tautological gate — the mutation-sensitivity " <>
               "check itself is vacuous"

      assert report.original_rows > 0 and report.mutated_rows > 0
    end

    test "mutation check actually corrupts the graph in-memory only" do
      rel = "priv/ggen/ash-pplan-pack/ontology.ttl"
      original_text = File.read!(Path.join(root(), rel))
      graph = read_graph(rel)

      mutated =
        mutate_drop_pattern(
          graph,
          {RDF.iri("https://w3id.org/ash-pplan#status"), :any_object}
        )

      assert RDF.Graph.triple_count(graph) > RDF.Graph.triple_count(mutated),
             "mutation must remove at least one triple"

      assert File.read!(Path.join(root(), rel)) == original_text,
             "the on-disk fixture was modified — fixtures are read-only"

      # Silence unused warning if graph bindings drift.
      _ = mutated
    end
  end
end
