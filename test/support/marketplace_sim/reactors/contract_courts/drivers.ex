defmodule AshPPlan.Sim.Marketplace.Reactors.ContractCourts.Drivers do
  @moduledoc """
  Input builders for driving the marketplace_sim reactor subject family:
  one builder per subject plus the portal JWT issuer. Kept separate from the
  engine so the mutant subject family can reuse the exact same drives.
  """

  alias AshPPlan.Examples.UltraCode.Steps
  alias AshPPlan.Sim.Marketplace.Vendor.Portal

  @aud "marketplace"
  @now 1_700_000_000
  @ts 1_700_000_500
  @pool_id :rcr_court_pool
  @pool_committed 10_000

  @doc "Issues a deterministic signup JWT (same claims -> same token string)."
  def issue(ctx, attrs) do
    Portal.issue(ctx.portal, Keyword.merge(attrs, now: @now))
  end

  def signup_inputs(ctx, account_id, token) do
    %{
      portal: ctx.portal,
      api: ctx.api,
      jwt: token,
      now: @now,
      aud: @aud,
      account_id: account_id,
      entitlement_id: account_id <> "-ent"
    }
  end

  def activation_inputs(ctx, account_id) do
    %{api: ctx.api, account_id: account_id, entitlement_id: account_id <> "-ent"}
  end

  def usage_inputs(ctx, run_id) do
    %{
      store: ctx.store,
      run_id: run_id,
      source: Steps.workflow(),
      inputs: %{frontier: [%{id: :a, status: :open, deps: []}]},
      metering: ctx.metering,
      entitlement_id: "rc-acct-1-ent",
      ts: @ts
    }
  end

  def report_inputs(ctx, report_ref, ent_id) do
    %{
      metering: ctx.metering,
      entitlement_id: ent_id,
      window_from: @ts - 100,
      window_to: @ts + 100,
      consumer_id: "rc-acct-1",
      report_ref: report_ref,
      pool_id: @pool_id,
      pool_committed: @pool_committed
    }
  end
end
