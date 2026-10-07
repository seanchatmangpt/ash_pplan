# GENERATED-PROVENANCE: EEx projection of
#   packs/ash-runtime-integration-contract-pack/templates/exact_subject.ex.tmpl (Tera) at marketplace pin
#   6f779318a20aeb3babe3968d952d733d509bdc15, applied by
#   priv/ggen/ash-pplan-runtime-overlay driver bin/manufacture-runtime-contract
#   and priv/ggen/vendor/sync.sh. Editing this file by hand is a refused
#   transition: edit the pack template upstream (and the consumer rows in
#   the overlay ontology) and re-vendor + re-sync.
defmodule AshPPlan.RuntimeContract.ExactSubject do
  @moduledoc false
  @repo "ash_pplan"
  @base "c42ee1989db28cf544b26a0d13e084a3e1d4c7da"
  @head "c42ee1989db28cf544b26a0d13e084a3e1d4c7da"

  def identity, do: %{repo: @repo, base: @base, head: @head}
  def exact?(%{repo: @repo, base: @base, head: @head}), do: true
  def exact?(_), do: false
end
