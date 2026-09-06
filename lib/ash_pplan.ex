defmodule AshPPlan do
  @moduledoc """
  P-PLAN/PROV-O semantic projection into the existing Ash process stack.

  `AshPPlan` intentionally owns no scheduler, queue, retry engine, transaction
  engine, or workflow executor. Those capabilities remain with Reactor,
  Ash.Reactor, AshOban/Oban, and Ash.
  """

  alias AshPPlan.Generated.ProjectionCatalog

  @version "26.9.6"

  @doc "Returns the ash_pplan release version."
  def version, do: @version

  @doc "Returns every ontology-to-runtime projection manufactured from `ontology.ttl`."
  def projections, do: ProjectionCatalog.all()

  @doc "Looks up a projection by its public/source ontology IRI."
  def projection(source_iri) when is_binary(source_iri), do: ProjectionCatalog.fetch(source_iri)

  @doc "Returns projections for a semantic role such as `:plan`, `:step`, or `:temporal`."
  def projections_for(role) when is_atom(role), do: ProjectionCatalog.by_role(Atom.to_string(role))
  def projections_for(role) when is_binary(role), do: ProjectionCatalog.by_role(role)

  @doc "Executes a Reactor without introducing an ash_pplan execution runtime."
  def run(reactor, inputs, context \\ %{}, options \\ []) do
    Reactor.run(reactor, inputs, context, options)
  end
end
