import Config

# Test-only application adapters (live in test/support, never in lib).
config :ash_pplan, :extra_adapters, %{
  ultracode: AshPPlan.Reactor.Adapters.Ultracode,
  selfhost: AshPPlan.Examples.Selfhost.Adapter,
  qf_ledger: AshPPlan.Examples.QualifiedFulfillment.Ledger.Adapter
}

# Example-application capability families (test support only).
config :ash_pplan,
       :extra_capability_families,
       ~w(actuator agent human order payment repository schedule shipment work)a
