defmodule AshPPlan.Sim.Marketplace.MarketplaceSimTest do
  @moduledoc """
  End-to-end marketplace-sim court: real Reactor runs over real sim processes
  (portal JWT, ProcurementApi, Pub/Sub, metering, billing) plus a real durable
  `AshPPlan.Workflow.Runtime.run` per usage event. Chicago-style: assert on
  real process state, no mocks.

  Anti-vacuity probes: expired-JWT signup refusal leaves no account, duplicate
  run id does not double-count usage, duplicate report ref does not double-
  draw the committed pool.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Examples.UltraCode.Steps
  alias AshPPlan.Reactor.Durable.{Clock, Store.Ets}
  alias AshPPlan.Reactor.Durable.LedgerOCEL
  alias AshPPlan.Sim.Marketplace.Google.ProcurementApi
  alias AshPPlan.Sim.Marketplace.Google.Pubsub

  alias AshPPlan.Sim.Marketplace.Reactors.{
    ActivationReactor,
    ReportingReactor,
    SignupReactor,
    UsageReactor
  }

  alias AshPPlan.Sim.Marketplace.Support
  alias AshPPlan.Sim.Marketplace.Vendor.Portal
  alias Vendor.{Billing, MeteringServer}

  @aud "marketplace"
  @now 1_700_000_000
  @pool_id :edp_pool_test
  @pool_committed 10_000
  @ts 1_700_000_500

  setup do
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)

    {:ok, store} = Ets.start_link()
    sim = Support.start_marketplace()
    :ok = Billing.allocate(@pool_id, @pool_committed)

    %{
      store: store,
      sim: sim,
      api: sim.api,
      portal: sim.portal,
      metering: sim.metering,
      pubsub: sim.pubsub
    }
  end

  defp signup(ctx, account_id, token) do
    Reactor.run(SignupReactor, %{
      portal: ctx.portal,
      api: ctx.api,
      jwt: token,
      now: @now,
      aud: @aud,
      account_id: account_id,
      entitlement_id: account_id <> "-ent"
    })
  end

  defp activate(ctx, account_id) do
    Reactor.run(ActivationReactor, %{
      api: ctx.api,
      account_id: account_id,
      entitlement_id: account_id <> "-ent"
    })
  end

  defp usage(ctx, run_id) do
    Reactor.run(UsageReactor, %{
      store: ctx.store,
      run_id: run_id,
      source: Steps.workflow(),
      inputs: %{frontier: [%{id: :a, status: :open, deps: []}]},
      metering: ctx.metering,
      entitlement_id: "acct-1-ent",
      ts: @ts
    })
  end

  defp report(ctx, report_ref, ent_id \\ "acct-1-ent") do
    Reactor.run(ReportingReactor, %{
      metering: ctx.metering,
      entitlement_id: ent_id,
      window_from: @ts - 100,
      window_to: @ts + 100,
      consumer_id: "acct-1",
      report_ref: report_ref,
      pool_id: @pool_id,
      pool_committed: @pool_committed
    })
  end

  defp decode(envelope) do
    {:ok, json} = Base.url_decode64(envelope.data, padding: false)
    Jason.decode!(json)
  end

  defp collect_pubsub(n, timeout \\ 2000) do
    Enum.map(1..n//1, fn _ ->
      assert_receive {:"$gen_cast", {:pubsub_message, _topic, envelope}}, timeout
      decode(envelope)
    end)
  end

  test "happy path: signup -> activation -> two real runs -> report decrements the pool", %{
    store: store,
    portal: portal,
    api: api,
    metering: metering,
    pubsub: pubsub
  } do
    Pubsub.subscribe(pubsub, "google-procurement")

    # -- signup --
    {:ok, token} =
      Portal.issue(portal, sub: "acct-1", aud: @aud, now: @now, exp_seconds: 3600)

    assert {:ok, %{account: account, entitlement: ent}} =
             signup(%{portal: portal, api: api}, "acct-1", token)

    assert account.state == "ACCOUNT_CREATED"
    assert ent.status == "ENTITLEMENT_ACTIVATION_REQUESTED"

    # -- activation: account approved BEFORE entitlement activation --
    assert {:ok, %{entitlement: active}} = activate(%{api: api}, "acct-1")
    assert active.status == "ENTITLEMENT_ACTIVE"
    assert {:ok, approved} = ProcurementApi.get_account(api, "acct-1")
    assert approved.approved? == true

    # journal ordering: creation < active, and both journaled once
    journal = ProcurementApi.event_journal(api)
    types = Enum.map(journal, & &1.event_type)
    assert types == ["ENTITLEMENT_CREATION_REQUESTED", "ENTITLEMENT_ACTIVE"]

    # lifecycle events published in order
    events = collect_pubsub(2)

    assert Enum.map(events, & &1["eventType"]) == [
             "ENTITLEMENT_CREATION_REQUESTED",
             "ENTITLEMENT_ACTIVE"
           ]

    # -- two real durable runs through UsageReactor --
    assert {:ok, %{run: run1, usage: :recorded}} =
             usage(%{store: store, metering: metering}, "wf-1")

    assert {:ok, %{run: run2, usage: :recorded}} =
             usage(%{store: store, metering: metering}, "wf-2")

    assert run1.observation.state == :succeeded
    assert run2.observation.state == :succeeded

    # duplicate run_id posts no new usage
    assert {:ok, :duplicate} =
             MeteringServer.post_usage(
               metering,
               "acct-1-ent",
               "plan_solve-wf-1",
               "plan_solve",
               500,
               @ts
             )

    assert {:ok, totals} = MeteringServer.totals(metering)
    assert totals == %{"acct-1-ent" => 1000}

    # evidence: each completed run exported real OCEL events carrying the run id
    for run_id <- ["wf-1", "wf-2"] do
      assert {:ok, events} = LedgerOCEL.events(store, run_id)
      assert match?([_ | _], events)
      assert Enum.any?(events, &(&1.id =~ "run:#{run_id}"))
    end

    # -- reporting draws down exactly the two events' worth --
    assert {:ok,
            %{
              payload: payload,
              total: 1000,
              drawdown: :recorded,
              balance: %{committed: 10_000, spent: 1000, remaining: 9000}
            }} = report(%{metering: metering}, "report-1")

    assert payload["operationId"] == "report-1"
    assert payload["consumerId"] == "project:acct-1"

    assert %{"int64Value" => 1000} =
             payload |> get_in(["metricValueSets"]) |> hd() |> Map.get("metricValues") |> hd()

    assert {:ok, {10_000, 1000, 9000}} = Billing.balance(@pool_id)
  end

  test "refusal: expired JWT is refused at signup and no account is created", %{
    portal: portal,
    api: api
  } do
    {:ok, token} = Portal.issue(portal, sub: "acct-2", aud: @aud, now: @now, exp_seconds: -60)

    assert {:error, error} = signup(%{portal: portal, api: api}, "acct-2", token)
    assert inspect(error) =~ "jwt_refused"
    assert inspect(error) =~ "expired"

    assert :error = ProcurementApi.get_account(api, "acct-2")
    assert [] = ProcurementApi.event_journal(api)
  end

  test "refusal: wrong-audience JWT is refused at signup", %{portal: portal, api: api} do
    {:ok, token} =
      Portal.issue(portal, sub: "acct-3", aud: "some-one-else", now: @now, exp_seconds: 3600)

    assert {:error, error} = signup(%{portal: portal, api: api}, "acct-3", token)
    assert inspect(error) =~ "jwt_refused"
    assert inspect(error) =~ "wrong_aud"
    assert :error = ProcurementApi.get_account(api, "acct-3")
  end

  test "idempotency: re-running the same report ref does not double-draw", %{
    metering: metering,
    api: api
  } do
    # seed usage directly, then report twice with the same ref
    {:ok, _} = ProcurementApi.create_account(api, "acct-4")

    assert {:ok, :recorded} =
             MeteringServer.post_usage(
               metering,
               "acct-4-ent",
               "plan_solve-wf-9",
               "plan_solve",
               250,
               @ts
             )

    assert {:ok, %{drawdown: :recorded, balance: %{spent: 250}}} =
             report(%{metering: metering}, "report-dup", "acct-4-ent")

    assert {:ok, %{drawdown: :duplicate, balance: %{spent: 250}}} =
             report(%{metering: metering}, "report-dup", "acct-4-ent")
  end
end
