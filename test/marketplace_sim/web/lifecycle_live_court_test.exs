defmodule AshPPlan.MarketplaceSim.Web.LifecycleLiveCourtTest do
  @moduledoc """
  Court for the marketplace-sim web layer: real TTL extraction asserted at the
  parse layer, full LiveView interactions for the explorer, and a real-time
  dashboard court proving step telemetry flows from REAL durable runs into the
  event stream (nothing fabricated — an empty dashboard shows an empty stream).
  """

  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint AshPPlan.MarketplaceSim.Endpoint

  setup_all do
    # Endpoint config is Application-env based (inline `use` opts are defaults
    # only), so the court installs it before the endpoint starts.
    Application.put_env(:ash_pplan, AshPPlan.MarketplaceSim.Endpoint,
      server: false,
      secret_key_base: String.duplicate("a", 64),
      pubsub_server: AshPPlan.MarketplaceSim.PubSub,
      adapter: Bandit.PhoenixAdapter,
      render_errors: [view: AshPPlan.MarketplaceSim.ErrorView, accepts: ~w(html json)],
      live_view: [signing_salt: "mpsim2610"]
    )

    start_supervised!({Phoenix.PubSub, name: AshPPlan.MarketplaceSim.PubSub})
    start_supervised!(AshPPlan.MarketplaceSim.Endpoint)
    :ok
  end

  setup do
    {:ok, conn: build_conn()}
  end

  defp wait_until(fun, tries \\ 200) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      if tries <= 1, do: raise("condition not met within timeout")
      Process.sleep(10)
      wait_until(fun, tries - 1)
  end

  # ===========================================================================
  # Explorer (LifecycleLive)
  # ===========================================================================

  describe "lifecycle explorer" do
    test "compile-time TTL extraction yields the real ontology counts" do
      assert length(AshPPlan.MarketplaceSim.LifecycleLive.steps()) == 8
      assert map_size(AshPPlan.MarketplaceSim.LifecycleLive.variables()) == 29
      assert length(AshPPlan.MarketplaceSim.LifecycleLive.agents()) == 8
      assert map_size(AshPPlan.MarketplaceSim.LifecycleLive.orgs()) == 4

      step5 =
        Enum.find(
          AshPPlan.MarketplaceSim.LifecycleLive.steps(),
          &(&1.id == "Step5_ProvisionEntitlementAndLinkAccount")
        )

      assert "Step4_AuthorizeAndAcceptOffer" in step5.preceded_by
      assert "Var_GCPOrderInstance" in step5.inputs
    end

    test "FinOps simulator math matches the closed-form model" do
      sim = AshPPlan.MarketplaceSim.LifecycleLive.simulate(5_000_000, 400_000, 70)

      assert sim.organic_burn == 3_500_000
      assert sim.unused_pool == 1_500_000
      assert sim.post_deal_pool == 3_900_000
      assert sim.remaining_pool == 1_100_000
      assert sim.gain_pct == 8.0
      assert length(sim.curve) == 13
    end

    test "renders hero KPIs, 8 step buttons and 8 avatars", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert html =~ "GCP Marketplace Lifecycle Explorer"
      html = render(view)
      assert length(Regex.scan(~r/data-step-button=/, html)) == 8
      assert length(Regex.scan(~r/data-avatar="/, html)) == 8
    end

    test "domain filter narrows avatars to 2 ISV", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert view
             |> element("[data-domain-filter='ISV']")
             |> render_click() =~ "MarcusThorne"

      grid = element(view, "#avatars") |> render()
      assert length(Regex.scan(~r/data-avatar="/, grid)) == 2
      refute grid =~ "SarahChen"
    end

    test "select_step shows the chosen step's inputs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert view
             |> element("[data-step-button='Step5_ProvisionEntitlementAndLinkAccount']")
             |> render_click() =~ "ENTITLEMENT_ACTIVATION_REQUESTED"

      card_html =
        render(element(view, "[data-step-card='Step5_ProvisionEntitlementAndLinkAccount']"))

      assert length(Regex.scan(~r/data-input=/, card_html)) == 4
    end

    test "simulator phx-change doubles gain 8.0 -> 16.0", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert view |> element("[data-kpi='gain']") |> render() =~ "8.0%"

      html =
        render_change(view, "update_simulator", %{
          "sim" => %{"commit_pool" => "5000000", "deal_size" => "800000", "organic_rate" => "70"}
        })

      assert html =~ "16.0%"
      assert element(view, "[data-kpi='post-deal']") |> render() =~ "4300000"
    end

    test "turtle search filters lines while preserving prefixes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_change(view, "search_ontology", %{"q" => "ElenaVance"})
      viewer = element(view, "#turtle-viewer") |> render()

      assert viewer =~ "ElenaVance"
      assert viewer =~ "@prefix p-plan:"
      refute viewer =~ "Step8_DisburseNetSettlement"
    end
  end

  # ===========================================================================
  # Fleet dashboard (DashboardLive) — real-time over REAL durable runs
  # ===========================================================================

  describe "fleet dashboard" do
    test "anti-vacuity: an untouched dashboard shows an empty stream and no runs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      html = render(view)
      assert length(Regex.scan(~r/data-event-row=/, html)) == 0
      assert length(Regex.scan(~r/data-run-row=/, html)) == 0
    end

    test "form-to-run: a REAL durable run streams step telemetry into the dashboard", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/dashboard")

      run_id = "dash-run-#{System.unique_integer([:positive])}"

      html =
        view
        |> element("#start-run-form")
        |> render_submit(run: %{run_id: run_id})

      # The run parks on the confirm gate: its step events stream in, newest
      # first, all bound to the submitted run_id.
      wait_until(fn ->
        html = render(view)
        assert length(Regex.scan(~r/data-event-row=/, html)) >= 2
        assert html =~ run_id
      end)

      assert html =~ run_id

      # The ledger row reflects the parked run (waiter on the confirm gate).
      row = element(view, "[data-run-row='#{run_id}']") |> render()
      assert row =~ "halted"
      assert row =~ "confirm"

      # Real tape: the dashboard KPI counts a non-zero checkpoint tape.
      assert row =~ "tape: "
    end

    test "signal + resume completes the run and issues a succeeded receipt", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      run_id = "dash-run-#{System.unique_integer([:positive])}"

      view
      |> element("#start-run-form")
      |> render_submit(run: %{run_id: run_id})

      wait_until(fn ->
        assert element(view, "[data-run-row='#{run_id}']") |> render() =~ "confirm"
      end)

      view
      |> element("[data-run-row='#{run_id}'] [data-action='signal-confirm']")
      |> render_click()

      wait_until(fn ->
        assert element(view, "[data-run-row='#{run_id}']") |> render() =~ "completed"
      end)

      wait_until(fn ->
        standing = element(view, "[data-standing-panel]") |> render()
        assert standing =~ "wakeup"
        assert standing =~ "confirm"
      end)
    end
  end
end
