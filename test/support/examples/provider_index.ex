defmodule AshPPlan.Test.Examples.ProviderIndex do
  @moduledoc """
  Test support: the generic shipped provider index plus the example providers
  manufactured by `bin/manufacture-examples` from `examples.ttl`.
  """

  @example_providers [
    AshPPlan.Generated.Providers.Actuator,
    AshPPlan.Generated.Providers.Artifact,
    AshPPlan.Generated.Providers.DurableGate,
    AshPPlan.Generated.Providers.EvidenceLocal,
    AshPPlan.Generated.Providers.FulfillmentManual,
    AshPPlan.Generated.Providers.Order,
    AshPPlan.Generated.Providers.Payment,
    AshPPlan.Generated.Providers.PaymentBackup,
    AshPPlan.Generated.Providers.Scheduler,
    AshPPlan.Generated.Providers.UltracodeAgent,
    AshPPlan.Generated.Providers.UltracodeAuthority,
    AshPPlan.Generated.Providers.UltracodeEvidence,
    AshPPlan.Generated.Providers.UltracodeRepository,
    AshPPlan.Generated.Providers.UltracodeVerification,
    AshPPlan.Generated.Providers.UltracodeWork,
    AshPPlan.Generated.Providers.Worker
  ]

  @spec modules() :: [module()]
  def modules, do: AshPPlan.Generated.ProviderIndex.modules() ++ @example_providers
end
