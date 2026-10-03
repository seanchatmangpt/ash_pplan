defmodule AshPPlan.Test.Examples.ProviderIndex do
  @moduledoc """
  Test support: the generic shipped provider index plus the example providers
  manufactured by `bin/manufacture-examples` from `examples.ttl`.
  """

  @example_providers [
    AshPPlan.Providers.Actuator,
    AshPPlan.Providers.Artifact,
    AshPPlan.Providers.DurableGate,
    AshPPlan.Providers.EvidenceLocal,
    AshPPlan.Providers.FulfillmentManual,
    AshPPlan.Providers.Order,
    AshPPlan.Providers.Payment,
    AshPPlan.Providers.PaymentBackup,
    AshPPlan.Providers.Scheduler,
    AshPPlan.Providers.UltracodeAgent,
    AshPPlan.Providers.UltracodeAuthority,
    AshPPlan.Providers.UltracodeEvidence,
    AshPPlan.Providers.UltracodeRepository,
    AshPPlan.Providers.UltracodeVerification,
    AshPPlan.Providers.UltracodeWork,
    AshPPlan.Providers.Worker
  ]

  @spec modules() :: [module()]
  def modules, do: AshPPlan.Providers.Index.modules() ++ @example_providers
end
