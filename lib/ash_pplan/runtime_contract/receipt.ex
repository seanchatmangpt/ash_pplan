# GENERATED-PROVENANCE: EEx projection of
#   packs/ash-runtime-integration-contract-pack/templates/receipt.ex.tmpl (Tera) at marketplace pin
#   6f779318a20aeb3babe3968d952d733d509bdc15, applied by
#   priv/ggen/ash-pplan-runtime-overlay driver bin/manufacture-runtime-contract
#   and priv/ggen/vendor/sync.sh. Editing this file by hand is a refused
#   transition: edit the pack template upstream (and the consumer rows in
#   the overlay ontology) and re-vendor + re-sync.
defmodule AshPPlan.RuntimeContract.Receipt do
  @enforce_keys [:subject, :action, :result, :recorded_at]
  defstruct [:subject, :action, :result, :recorded_at, :replay_key]

  def new(subject, action, result, replay_key) do
    %__MODULE__{
      subject: subject,
      action: action,
      result: result,
      replay_key: replay_key,
      recorded_at: DateTime.utc_now()
    }
  end
end
