# GENERATED-PROVENANCE: EEx projection of
#   packs/ash-runtime-integration-contract-pack/templates/authority_gate.ex.tmpl (Tera) at marketplace pin
#   29c579082aefe57eda5695d13cd4edb76cb82b31, applied by
#   priv/ggen/ash-pplan-runtime-overlay driver bin/manufacture-runtime-contract
#   and priv/ggen/vendor/sync.sh. Editing this file by hand is a refused
#   transition: edit the pack template upstream (and the consumer rows in
#   the overlay ontology) and re-vendor + re-sync.
defmodule AshPPlan.RuntimeContract.AuthorityGate do
  @moduledoc false
  @allowed_action "CONSTRUCT"

  def authorize(%{action: @allowed_action, policy: policy}) when not is_nil(policy), do: :ok
  def authorize(%{action: action}), do: {:error, {:refused, :authority, action}}
  def authorize(_), do: {:error, {:refused, :authority, :missing_action}}
end
