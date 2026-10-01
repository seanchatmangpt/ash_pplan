defmodule AshPPlan.Reactor.Durable.StoreConformanceEtsTest do
  @moduledoc """
  Court: `Store.Ets` against the generated Store conformance suite
  (`AshPPlan.Test.StoreConformance`, manufactured from the store-conformance ontology).
  Anti-vacuity mutation: `store_conformance_dets_test.exs` runs deliberately broken stores
  through the same suite and requires each mutant to fail exactly the law it violates.
  """
  use AshPPlan.Test.StoreConformance,
    store: AshPPlan.Reactor.Durable.Store.Ets,
    start: fn -> AshPPlan.Reactor.Durable.Store.Ets.start_link() end
end
