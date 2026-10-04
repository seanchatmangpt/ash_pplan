defmodule AshPPlan.Reactor.RealizationAdapterCourtTest do
  @moduledoc """
  Guard court for adapter-binding drift: every `ap:Realization` in the workflow pack
  ontology declares an (adapter, operation) pair, and every such pair MUST name an
  operation the named adapter actually implements (`ops/0`).

  The court reads the real access API (`AshPPlan.Reactor.adapters/0` for the id->module
  map, `adapter.ops/0` for coverage) and the pack ontology file directly (read-only).
  Anti-vacuity: a minimum pair count bounds a silently emptied ontology, and each
  declared pair must also resolve through the real `adapter.step/2` (unknown ops are
  typed `{:error, %{reason: :unsupported, ...}}` refusals, not raises).
  """

  use ExUnit.Case, async: false

  @ontology_path "priv/ggen/ash-pplan-workflow-pack/ontology.ttl"

  @min_pairs 25

  # Parse every ap:Realization's (adapter, operation) pair straight from the pack
  # ontology source. Line-oriented by design: the generated turtle keeps each
  # Realization on one line, so no RDF library dependency is needed here.
  defp ontology_pairs do
    {:ok, body} = File.read(@ontology_path)

    ~r/ap:Realization.*ap:adapter\s+"([^"]+)"\s*;\s*ap:operation\s+"([^"]+)"/
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [adapter, op] -> {adapter, op} end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  test "every ontology (adapter, operation) pair is implemented by its adapter" do
    pairs = ontology_pairs()

    assert length(pairs) >= @min_pairs,
           "ontology shrank below #{@min_pairs} realizations (got #{length(pairs)})"

    adapters = AshPPlan.Reactor.adapters()

    unbound =
      for {adapter_id, op} <- pairs,
          adapter_id = String.to_atom(adapter_id),
          op = String.to_atom(op),
          module = adapters[adapter_id] || flunk("unknown adapter id #{adapter_id}"),
          op not in module.ops() do
        {adapter_id, op}
      end

    assert unbound == [],
           "ontology declares realizations with no adapter binding: #{inspect(unbound)}"
  end

  test "every declared pair resolves through the real adapter.step/2 API" do
    adapters = AshPPlan.Reactor.adapters()

    for {adapter_id, op} <- ontology_pairs(),
        adapter_id = String.to_atom(adapter_id),
        op = String.to_atom(op) do
      module = Map.fetch!(adapters, adapter_id)
      assert {:ok, {step, opts}} = module.step(op, [])
      assert Code.ensure_loaded?(step)
      assert :ok = AshPPlan.Reactor.validate_step(step)
      assert Keyword.keyword?(opts)
    end
  end

  test "anti-vacuity: an unimplemented op is a typed unsupported, never a raise" do
    assert {:error, %{reason: :unsupported, adapter: :local, detail: {:unknown_op, :nope}}} =
             AshPPlan.Reactor.Adapters.Local.step(:nope, [])

    assert {:error, %{reason: :unsupported, adapter: :durable, detail: {:unknown_op, :nope}}} =
             AshPPlan.Reactor.Adapters.Durable.step(:nope, [])
  end

  test "the two historically drifting pairs resolve end to end" do
    for {adapter_id, op} <- [{"local", "durability_checkpoint"}, {"local", "scheduling_wakeup"}] do
      r = %AshPPlan.Realization{
        capability: "Court.Fixture",
        provider: :court,
        binding: %{adapter: String.to_atom(adapter_id), op: String.to_atom(op)}
      }

      assert {:ok, {step, _opts}} = AshPPlan.Reactor.step_for(r)
      assert :ok = AshPPlan.Reactor.validate_step(step)
    end
  end
end
