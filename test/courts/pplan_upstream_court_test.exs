defmodule AshPPlan.Courts.PPlanUpstreamCourtTest do
  @moduledoc """
  Upstream-vocabulary court: ash_pplan must not maintain a private P-PLAN.

  The canonical P-PLAN 1.3 and PROV-O are vendored under priv/vendor/ from
  their authoritative sources (see priv/vendor/README.md). This court pins:

  1. The vendored files are the real canonical ontologies (version 1.3,
     17+ p-plan declarations, PROV-O namespace intact).
  2. Every p-plan: term used in ontology.ttl is declared in canonical
     upstream P-PLAN 1.3 — a private p-plan: term is a refusal.
  3. Every prov: term used in ontology.ttl is declared in canonical PROV-O
     (vendored from w3.org).
  4. ontology.ttl declares owl:imports of the canonical namespaces.
  """

  use ExUnit.Case, async: true

  @ontology_path "ontology.ttl"
  @pplan_owl "priv/vendor/p-plan-1.3/p-plan.owl"
  @prov_o "priv/vendor/prov-o/prov-o.ttl"

  @pplan_ns "http://purl.org/net/p-plan#"
  @prov_ns "http://www.w3.org/ns/prov#"

  defp read(path), do: File.read!(path)

  # -- upstream declaration extraction -----------------------------------------

  # The canonical P-PLAN ships as RDF/XML. RDF/XML declarations have the exact
  # shape `<owl:Class rdf:about="URI">` / `<owl:ObjectProperty rdf:about=...>`,
  # so a structural XML scan yields the declared-term set deterministically.
  # The RDF/XML uses XML entities (`&prov;`, `&terms;`, ...) inside some
  # rdf:about values, so declarations are expanded through the file's own
  # <!ENTITY ...> block before being collected.
  defp pplan_declared do
    xml = read(@pplan_owl)

    entities =
      Regex.scan(~r/<!ENTITY\s+(\w+)\s+"([^"]+)"\s*>/, xml)
      |> Map.new(fn [_, name, uri] -> {name, uri} end)

    expand = fn value ->
      Regex.replace(~r/&(\w+);/, value, fn _, name -> Map.get(entities, name, "&#{name};") end)
    end

    ~r/<owl:(Class|ObjectProperty|DatatypeProperty|FunctionalProperty|TransitiveProperty|AnnotationProperty)\s+rdf:about="([^"]+)"/
    |> Regex.scan(xml)
    |> MapSet.new(fn [_ | rest] -> expand.(List.last(rest)) end)
  end

  defp prov_declared do
    ttl = read(@prov_o)
    assert ttl != ""

    # PROV-O ships as Turtle; use the real parser.
    graph = RDF.Turtle.read_file!(@prov_o)

    query = """
    PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
    PREFIX owl: <http://www.w3.org/2002/07/owl#>
    SELECT ?s WHERE {
      ?s rdf:type ?t .
      FILTER(STRSTARTS(STR(?s), "#{@prov_ns}"))
      FILTER(?t IN (owl:Class, owl:ObjectProperty, owl:DatatypeProperty,
                    owl:AnnotationProperty))
    }
    """

    %SPARQL.Query.Result{results: results} = SPARQL.execute_query(graph, query)
    MapSet.new(results, fn sol -> sol["s"] |> RDF.Term.value() end)
  end

  # -- terms used in the projection ontology ------------------------------------

  defp pplan_terms_used do
    Regex.scan(~r/p-plan:([A-Za-z][A-Za-z0-9_]*)/, read(@ontology_path))
    |> MapSet.new(fn [_ | rest] -> hd(rest) end)
  end

  defp prov_terms_used do
    Regex.scan(~r/prov:([A-Za-z][A-Za-z0-9_]*)/, read(@ontology_path))
    |> MapSet.new(fn [_ | rest] -> hd(rest) end)
  end

  defp resolve(term, "p-plan"), do: @pplan_ns <> term
  defp resolve(term, "prov"), do: @prov_ns <> term

  # -- tests ---------------------------------------------------------------------

  test "vendored canonical P-PLAN 1.3 is the real ontology" do
    xml = read(@pplan_owl)
    assert xml =~ ~s(owl:versionInfo>1.3<)
    assert xml =~ ~s(xmlns="http://purl.org/net/p-plan#")
    assert xml =~ "Daniel Garijo"
    assert xml =~ "Yolanda Gil"
    declared = pplan_declared()
    assert MapSet.size(declared) >= 17

    for t <- ~w(Plan Step Variable Activity Entity Bundle MultiStep),
        do: assert(MapSet.member?(declared, @pplan_ns <> t))

    for t <-
          ~w(correspondsToStep correspondsToVariable hasInputVar hasOutputVar isPrecededBy isStepOfPlan isVariableOfPlan),
        do: assert(MapSet.member?(declared, @pplan_ns <> t))
  end

  test "vendored PROV-O parses and declares the terms we use" do
    declared = prov_declared()
    assert MapSet.size(declared) >= 20
  end

  test "every p-plan: term used in ontology.ttl is upstream-declared (no private p-plan)" do
    declared = pplan_declared()

    private =
      pplan_terms_used()
      |> MapSet.new(fn t -> resolve(t, "p-plan") end)
      |> MapSet.difference(declared)
      |> MapSet.to_list()

    assert private == [], "private p-plan: terms in ontology.ttl: #{inspect(private)}"
  end

  test "every prov: term used in ontology.ttl is PROV-O-declared" do
    declared = prov_declared()

    private =
      prov_terms_used()
      |> MapSet.new(fn t -> resolve(t, "prov") end)
      |> MapSet.difference(declared)
      |> MapSet.to_list()

    assert private == [], "terms not declared in canonical PROV-O: #{inspect(private)}"
  end

  test "ontology imports the canonical namespaces" do
    text = read(@ontology_path)
    assert text =~ "owl:imports <http://purl.org/net/p-plan#>"
    assert text =~ "<http://www.w3.org/ns/prov-o#>"
  end
end
