defmodule AshPPlan.Courts.OntologySemanticsCourtTest do
  @moduledoc """
  Court: ontology.ttl is the semantic source of truth; generated code must match it.

  - Every `ap:Capability` id in ontology.ttl must equal an entry in
    `AshPPlan.Workflow.CapabilityCatalog.all/0` (and the mapping must be exact, both directions).
  - Every generated provider module in `lib/ash_pplan/providers/` must declare its
    `@capabilities` subset of ontology capability ids.
  - Anti-vacuity: an empty/partial parse fails loudly via a >30 capability floor.
  """

  use ExUnit.Case, async: true

  @ontology_path "ontology.ttl"
  @providers_dir "lib/ash_pplan/providers"
  @min_capabilities 30

  defp ontology_capabilities do
    graph = RDF.Turtle.read_file!(@ontology_path)

    query = """
    PREFIX ap: <https://w3id.org/ash-pplan#>
    SELECT ?id ?family WHERE {
      ?cap a ap:Capability ; ap:capabilityId ?id ; ap:family ?family .
    }
    """

    case SPARQL.execute_query(graph, query) do
      %SPARQL.Query.Result{} = result ->
        result.results
        |> Enum.map(fn solution ->
          %{
            id: to_string(to_string(solution["id"])),
            family: to_string(to_string(solution["family"]))
          }
        end)
        |> Enum.uniq_by(& &1.id)

      other ->
        flunk("ontology.ttl SPARQL query failed: #{inspect(other)}")
    end
  end

  # Parse once; every test asserts on the same real on-disk state.
  setup_all do
    %{onto: ontology_capabilities()}
  end

  describe "anti-vacuity" do
    test "ontology parse is non-empty and exceeds the capability floor", %{onto: onto} do
      assert length(onto) > @min_capabilities,
             "ontology.ttl yielded #{length(onto)} ap:Capability entries; " <>
               "an empty or partial parse must fail loudly (floor: >#{@min_capabilities})"
    end

    test "SPARQL read agrees with a raw on-disk grep of capability lines" do
      ttl = File.read!(@ontology_path)

      raw =
        Regex.scan(~r/a ap:Capability ; ap:capabilityId "([^"]+)"/, ttl)
        |> Enum.map(&Enum.at(&1, 1))
        |> Enum.uniq()

      assert length(raw) > @min_capabilities
      assert length(raw) == 31, "raw line count drifted; update court with real count"
    end
  end

  describe "catalog ↔ ontology" do
    test "CapabilityCatalog.all/0 ids equal ontology capability ids exactly", %{onto: onto} do
      onto_ids = onto |> Enum.map(& &1.id) |> Enum.sort()
      catalog_ids = AshPPlan.Workflow.CapabilityCatalog.all() |> Enum.map(& &1.id) |> Enum.sort()

      assert onto_ids == catalog_ids,
             "drift between ontology and catalog — ontology-only: " <>
               inspect(onto_ids -- catalog_ids) <>
               "; catalog-only: " <> inspect(catalog_ids -- onto_ids)
    end

    test "families agree per capability id", %{onto: onto} do
      onto_map = Map.new(onto, &{&1.id, &1.family})
      catalog_map = Map.new(AshPPlan.Workflow.CapabilityCatalog.all(), &{&1.id, &1.family})

      Enum.each(onto_map, fn {id, family} ->
        assert catalog_map[id] == family,
               "family drift for #{id}: ontology=#{family} catalog=#{inspect(catalog_map[id])}"
      end)
    end
  end

  describe "providers ↔ ontology" do
    test "every generated provider's @capabilities is declared in the ontology", %{onto: onto} do
      onto_ids = MapSet.new(onto, & &1.id)

      provider_files =
        @providers_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".ex"))
        |> Enum.reject(&(&1 in ["index.ex", "registry.ex", "resolver.ex", "qualify.ex"]))

      assert length(provider_files) >= 10, "expected >=10 generated providers on disk"

      modules =
        provider_files
        |> Enum.map(fn f ->
          case Regex.run(~r/defmodule ([\w.]+)/, File.read!(Path.join(@providers_dir, f))) do
            [_, mod] -> String.to_atom("Elixir." <> mod)
            _ -> flunk("no defmodule found in #{f}")
          end
        end)

      for mod <- modules do
        assert Code.ensure_loaded?(mod), "provider module #{mod} not loadable"

        assert function_exported?(mod, :capabilities, 0),
               "#{mod} has no capabilities/0 — regenerate from ontology.ttl"

        for cap <- mod.capabilities() do
          assert MapSet.member?(onto_ids, cap),
                 "#{mod} declares capability #{inspect(cap)} not present in ontology.ttl"
        end
      end
    end
  end
end
