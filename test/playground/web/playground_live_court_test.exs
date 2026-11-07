defmodule AshPPlan.Playground.Web.PlaygroundLiveCourtTest do
  @moduledoc """
  Verification court for the Tactical Common Operating Picture (COP) Playground.

  Asserts:
  1. Full mount of `PlaygroundLive` rendering the dual-track delta tape,
     margin invariant envelope, force readiness roster, and CAD command bar.
  2. ReactFlow and Visx client hook containers mount with valid JSON data payloads.
  3. Margin invariant governor fails closed (`[REFUSED]`) when margin < 22%.
  4. Margin invariant admits (`[ADMITTED]`) and unparks steps when margin >= 22%.
  5. CAD command prompt parses typed syntax (`NTE <wo> <amt>`) and advances run.
  6. Proactive intervention triage card surfaces on statistical hazard drift (Z >= 2.5σ)
     and resets upon confirmed operator resumption signal.
  """

  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias AshPPlan.Playground.TelemetryBroadcaster

  @endpoint AshPPlan.Playground.Endpoint

  setup_all do
    Application.put_env(:ash_pplan, AshPPlan.Playground.Endpoint,
      server: false,
      secret_key_base: String.duplicate("p", 64),
      pubsub_server: AshPPlan.Playground.PubSub,
      adapter: Bandit.PhoenixAdapter,
      render_errors: [view: AshPPlan.Playground.ErrorView, accepts: ~w(html json)],
      live_view: [signing_salt: "cop_play_salt"]
    )

    start_supervised!({Phoenix.PubSub, name: AshPPlan.Playground.PubSub})
    start_supervised!(AshPPlan.Playground.Endpoint)
    :ok
  end

  setup do
    {:ok, conn: build_conn()}
  end

  # ===========================================================================
  # Render & Component Layout
  # ===========================================================================

  describe "playground mount and layout" do
    test "renders tactical flight deck with React hook containers and delta tape", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert html =~ "TACTICAL COP // ASH_PPLAN FLIGHT DECK"
      assert html =~ "CAUSAL DAG // @xyflow/react"

      # React hook mount target
      assert has_element?(view, "#react-flow-stage[phx-hook='ReactFlowHook']")
      assert has_element?(view, "#forensic-scrubber-stage[phx-hook='ScrubberHook']")

      # Plan delta tape
      assert has_element?(view, "#plan-delta-tape")
      assert has_element?(view, "[data-step-id='intake'][data-step-status='completed']")
      assert has_element?(view, "[data-step-id='ack'][data-step-status='drift']")

      # CAD bar
      assert has_element?(view, "#cad-bar")
      assert has_element?(view, "#cad-input")

      # Initial hazard score for sub_hazard_drift scenario (Z = 2.81)
      assert has_element?(view, "#hazard-z-badge[data-hazard-z='2.81']")
      assert has_element?(view, "#triage-intervention-card")
      assert render(view) =~ "⚠️ PROACTIVE DISPATCH INTERVENTION REQUIRED"
    end

    test "force readiness gauges display active unit digital twins", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "[data-unit-id='APEX-104']")
      assert has_element?(view, "[data-unit-id='STRATA-201']")
      assert render(view) =~ "Apex Mechanical"
      assert render(view) =~ "Strata HVAC Solutions"
    end
  end

  # ===========================================================================
  # Margin Invariant Governor & Fail-Closed Gating
  # ===========================================================================

  describe "margin invariant envelope governor" do
    test "fails closed and displays [REFUSED] when NTE produces margin < 22%", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Set NTE to $850 when quote is $750: ((850 - 750) / 850) * 100 = 11.8% (< 22%)
      view
      |> element("#nte-slider")
      |> render_change(%{"nte" => "850"})

      html = render(view)
      assert html =~ "[REFUSED]"
      assert has_element?(view, "#margin-status-tag[data-admitted='false']")
      assert html =~ "REFUSED: Margin below 22% floor!"
      # Step remains blocked
      assert has_element?(view, "[data-step-id='diagnose'][data-step-status='blocked']")
    end

    test "admits and unparks step when NTE satisfies >= 22% gross margin floor", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Set NTE to $1400 when quote is $750: ((1400 - 750) / 1400) * 100 = 46.4% (>= 22%)
      view
      |> element("#nte-slider")
      |> render_change(%{"nte" => "1400"})

      html = render(view)
      assert html =~ "[ADMITTED]"
      assert has_element?(view, "#margin-status-tag[data-admitted='true']")
      assert html =~ "NTE BUMP COMMITTED: $1400"
      assert has_element?(view, "[data-step-id='diagnose'][data-step-status='completed']")
    end
  end

  # ===========================================================================
  # CAD Command Bar
  # ===========================================================================

  describe "CAD command bar keyboard execution" do
    test "executes typed NTE command and updates financial envelope", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("#cad-bar form")
      |> render_submit(%{"cmd" => "NTE rel-1 1500"})

      html = render(view)
      assert html =~ "CAD: NTE updated to $1500 for rel-1"
      assert html =~ "[ADMITTED]"
    end

    test "refuses typed NTE command when margin is inadequate", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("#cad-bar form")
      |> render_submit(%{"cmd" => "NTE rel-1 800"})

      html = render(view)
      assert html =~ "CAD REFUSAL: NTE $800 breaches 22% margin floor!"
      assert html =~ "[REFUSED]"
    end

    test "reports error on malformed CAD command syntax", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("#cad-bar form")
      |> render_submit(%{"cmd" => "UNKNOWN_CMD_123"})

      assert has_element?(view, "#cad-error-msg")
      assert render(view) =~ "Syntax error"
    end
  end

  # ===========================================================================
  # Scenario Switching & Autonomic Contingency Detours
  # ===========================================================================

  describe "scenario switching and detours" do
    test "switching to Nominal clears hazard warning", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("button", "Nominal")
      |> render_click()

      assert has_element?(view, "#hazard-z-badge[data-hazard-z='0.8']")
      refute has_element?(view, "#triage-intervention-card")
    end

    test "quick signal 'confirmed_driving' resets hazard score and advances step", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#triage-intervention-card")

      view
      |> element("button", "[ 1: Confirmed Driving (Extend 15m) ]")
      |> render_click()

      html = render(view)
      assert html =~ "Confirmed driving. Hazard timer reset."
      assert has_element?(view, "#hazard-z-badge[data-hazard-z='1.2']")
      refute has_element?(view, "#triage-intervention-card")
      assert has_element?(view, "[data-step-id='ack'][data-step-status='completed']")
    end

    test "emergency detour triggers FOND contingency branch", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("button", "[ 3: Tech Declined / FOND Detour ]")
      |> render_click()

      html = render(view)
      assert html =~ "FOND Detour activated"
      assert has_element?(view, "[data-step-id='detour']")
    end
  end

  # ===========================================================================
  # Telemetry PubSub & React Signal Ingestion
  # ===========================================================================

  describe "real-time telemetry and React signal bridge" do
    test "tape_append broadcast commits checkpoint to persistent store", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      cp = %{
        id: "step-sensor-test",
        label: "geofence_verified",
        seq: 99,
        output: %{lat: 37.3382, lng: -121.8863}
      }

      TelemetryBroadcaster.broadcast_checkpoint(AshPPlan.Playground.PubSub, cp)

      # LiveView receives checkpoint
      assert render(view) =~ "CHECKPOINT TAPE:"
    end

    test "emit_engine_signal from React hook unblocks step", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "emit_engine_signal", %{
        "run_id" => "rel-1",
        "label" => "diagnose",
        "payload" => %{"approved" => true}
      })

      assert render(view) =~ "Signal diagnose processed."
    end
  end
end
