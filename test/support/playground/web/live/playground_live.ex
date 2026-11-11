defmodule AshPPlan.Playground.PlaygroundLive do
  @moduledoc """
  Root LiveView orchestrating the Tactical Common Operating Picture (COP) Playground.

  Integrates:
  - Incident Action Plan (IAP) baseline vs. COP physical reality.
  - Client hooks mounting @xyflow/react canvas and timeline scrubber.
  - CAD command prompt with short syntax parsing.
  - Gross margin invariant envelope governor with fail-closed refusals.
  - Point-to-point resumptions via `AshPPlan.Playground.EngineBridge`.
  """

  use Phoenix.LiveView

  import AshPPlan.Playground.CopComponents,
    only: [
      plan_delta_tape: 1,
      margin_invariant_envelope: 1,
      force_readiness_gauge: 1,
      triage_incident_card: 1,
      incident_triage_queue: 1,
      telemetry_live_ticker: 1,
      tactical_radar_kpis: 1
    ]

  alias AshPPlan.Playground.{CadCommandBar, EngineBridge, ScenarioRunner, TelemetryBroadcaster}
  alias AshPPlan.Reactor.Durable.Store.Ets

  @impl true
  def mount(_params, _session, socket) do
    {:ok, store} = Ets.start_link()
    scenario = :sub_hazard_drift
    incident = ScenarioRunner.default_incident(scenario)
    units = ScenarioRunner.default_units()
    incidents = ScenarioRunner.multi_incident_roster()

    # Pre-seed the scenario in the durable store
    {:ok, _record} = EngineBridge.start_scenario(store, scenario, incident.run_id)
    tape = EngineBridge.get_run_tape(store, incident.run_id)

    if connected?(socket) do
      # Subscribe to COP topics — delivery is pubsub-agnostic (:pg groups,
      # see AshPPlan.Playground.TelemetryBroadcaster).
      TelemetryBroadcaster.subscribe(TelemetryBroadcaster.topic_telemetry())
      TelemetryBroadcaster.subscribe(TelemetryBroadcaster.topic_incidents())
    end

    initial_logs = [
      %{
        id: "INIT-1",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        level: "INFO",
        subsystem: "FLEET_MONITOR",
        message: "Tactical Common Operating Picture initialized across 5 facility nodes."
      },
      %{
        id: "INIT-2",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        level: "TELEMETRY",
        subsystem: "BMS_SYNC",
        message: "Modbus RTU poll synchronized: 100% telemetry fidelity verified."
      }
    ]

    {:ok,
     socket
     |> assign(:store, store)
     |> assign(:selected_scenario, scenario)
     |> assign(:incident, incident)
     |> assign(:units, units)
     |> assign(:tape, tape)
     |> assign(:incidents, incidents)
     |> assign(:selected_incident_id, "INC-0921")
     |> assign(:logs, initial_logs)
     |> assign(:tick_count, 0)
     |> assign(:last_status_msg, nil)}
  end

  @impl true
  def terminate(_reason, socket) do
    if store = socket.assigns[:store] do
      try do
        GenServer.stop(store, :normal)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # -- Render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen w-screen bg-black text-zinc-100 flex flex-col p-3 gap-2 overflow-hidden select-none font-sans">
      <!-- Top Row: Operational Status, Scenario Switcher & CAD Bar -->
      <header class="flex items-center justify-between gap-4 border-b border-zinc-850 pb-2">
        <div class="flex items-center gap-3">
          <span class="h-2.5 w-2.5 rounded-full bg-emerald-500 animate-ping" />
          <div>
            <h1 class="font-mono font-black text-xs tracking-widest text-zinc-200">
              TACTICAL COP // ASH_PPLAN FLIGHT DECK
            </h1>
            <div class="text-[10px] font-mono text-zinc-400">
              ACTIVE RUN: <strong class="text-zinc-200">{@incident.run_id}</strong> |
              SELECTED INCIDENT: <strong class="text-cyan-400">{@selected_incident_id}</strong>
            </div>
          </div>
        </div>

        <!-- Scenario Switcher Buttons -->
        <div class="flex items-center gap-1 font-mono text-[10px]">
          <button
            phx-click="select_scenario"
            phx-value-scenario="nominal"
            class={[
              "px-2 py-1 rounded border",
              @selected_scenario == :nominal && "bg-emerald-950 text-emerald-300 border-emerald-700",
              @selected_scenario != :nominal && "bg-zinc-900 text-zinc-400 border-zinc-800"
            ]}
          >
            Nominal
          </button>
          <button
            phx-click="select_scenario"
            phx-value-scenario="sub_hazard_drift"
            class={[
              "px-2 py-1 rounded border",
              @selected_scenario == :sub_hazard_drift && "bg-amber-950 text-amber-300 border-amber-700",
              @selected_scenario != :sub_hazard_drift && "bg-zinc-900 text-zinc-400 border-zinc-800"
            ]}
          >
            Hazard Drift
          </button>
          <button
            phx-click="select_scenario"
            phx-value-scenario="margin_breach"
            class={[
              "px-2 py-1 rounded border",
              @selected_scenario == :margin_breach && "bg-rose-950 text-rose-300 border-rose-700",
              @selected_scenario != :margin_breach && "bg-zinc-900 text-zinc-400 border-zinc-800"
            ]}
          >
            Margin Breach
          </button>
          <button
            phx-click="select_scenario"
            phx-value-scenario="contingency_detour"
            class={[
              "px-2 py-1 rounded border",
              @selected_scenario == :contingency_detour && "bg-cyan-950 text-cyan-300 border-cyan-700",
              @selected_scenario != :contingency_detour && "bg-zinc-900 text-zinc-400 border-zinc-800"
            ]}
          >
            FOND Detour
          </button>
        </div>

        <div class="w-1/3">
          <.live_component module={CadCommandBar} id="cad-bar" />
        </div>
      </header>

      <!-- KPI Summary Strip -->
      <.tactical_radar_kpis incidents={@incidents} tick_count={@tick_count} />

      <!-- Main Stage: Left Triage (25%) + Center Stage (50%) + Right Rail (25%) -->
      <main class="flex-1 grid grid-cols-12 gap-2 min-h-0">
        <!-- Left Rail: Multi-Incident Triage Queue (Hive Stream) -->
        <section class="col-span-3 h-full min-h-0">
          <.incident_triage_queue incidents={@incidents} selected_id={@selected_incident_id} />
        </section>

        <!-- Center Stage: Live Causal DAG + Plan Delta Tape -->
        <section class="col-span-6 flex flex-col gap-2 h-full min-h-0">
          <!-- React Flow Canvas Container (mounted via client hook) -->
          <div class="flex-1 bg-zinc-950 border border-zinc-800 rounded-lg overflow-hidden relative min-h-[220px]">
            <div class="absolute top-2 left-2 z-10 font-mono text-[10px] text-zinc-400 bg-zinc-900/90 px-2 py-1 rounded border border-zinc-800">
              CAUSAL DAG // @xyflow/react
            </div>

            <!-- React hook mount target -->
            <div
              id="react-flow-stage"
              phx-hook="ReactFlowHook"
              phx-update="ignore"
              data-run-id={@incident.run_id}
              data-steps={Jason.encode!(@incident.steps)}
              class="w-full h-full"
            >
              <!-- Static / SSR fallback when JS bundle is detached -->
              <div class="w-full h-full flex items-center justify-center font-mono text-xs text-zinc-500 p-4">
                <div class="text-center space-y-2">
                  <div class="text-zinc-400 font-bold">Interactive P-PLAN Topology Stage</div>
                  <div class="text-[11px] text-zinc-600">
                    Active Run: {@incident.run_id} | Checkpoints: {length(@tape)}
                  </div>
                </div>
              </div>
            </div>
          </div>

          <!-- Dual-track Delta Tape -->
          <.plan_delta_tape
            run_id={@incident.run_id}
            steps={@incident.steps}
            hazard_z={@incident.hazard_z}
          />

          <!-- Timeline Scrubber Container (mounted via client hook) -->
          <div
            id="forensic-scrubber-stage"
            phx-hook="ScrubberHook"
            phx-update="ignore"
            data-tape={Jason.encode!(@tape)}
            class="h-10 bg-zinc-950 border border-zinc-800 rounded-lg px-3 py-1 font-mono text-[10px] flex items-center justify-between text-zinc-400"
          >
            <span>FORENSIC TIMELINE SCRUBBER [VISX]</span>
            <span>CHECKPOINT TAPE: {length(@tape)} COMMITS</span>
          </div>
        </section>

        <!-- Right Rail: Triage Tray, Margin Envelope & Force Readiness -->
        <aside class="col-span-3 flex flex-col gap-2 overflow-y-auto pr-1">
          <%= if @incident.hazard_z >= 2.5 do %>
            <.triage_incident_card incident={@incident} />
          <% end %>

          <.margin_invariant_envelope
            client_nte={@incident.client_nte}
            sub_quote={@incident.sub_quote}
            floor_pct={@incident.floor_pct}
          />

          <!-- Parameter Invariant Slider -->
          <div class="bg-zinc-950 border border-zinc-800 rounded p-3 font-mono text-xs space-y-2">
            <div class="flex justify-between items-center text-zinc-400 text-[11px]">
              <span>ADJUST NTE CEILING:</span>
              <span class="text-zinc-200 font-bold">${@incident.client_nte}</span>
            </div>
            <input
              id="nte-slider"
              type="range"
              min="800"
              max="2000"
              step="50"
              value={@incident.client_nte}
              phx-change="adjust_nte"
              name="nte"
              class="w-full accent-emerald-500 cursor-pointer"
            />
          </div>

          <!-- Unit Force Readiness Roster -->
          <div class="space-y-2">
            <h3 class="font-mono text-xs text-zinc-400 font-bold uppercase tracking-wider">
              FORCE READINESS (UNITS)
            </h3>
            <%= for unit <- @units do %>
              <.force_readiness_gauge unit={unit} />
            <% end %>
          </div>

          <%= if @last_status_msg do %>
            <div
              id="last-status-toast"
              class="p-2 rounded font-mono text-[11px] bg-zinc-900 border border-zinc-750 text-emerald-400"
            >
              {@last_status_msg}
            </div>
          <% end %>
        </aside>
      </main>

      <!-- Bottom Stage: Live Scrolling Telemetry Ticker -->
      <footer>
        <.telemetry_live_ticker logs={@logs} tick_count={@tick_count} />
      </footer>
    </div>
    """
  end

  # -- Event Handlers ----------------------------------------------------------

  @impl true
  def handle_event("select_incident", %{"incident_id" => inc_id}, socket) do
    # Find incident in roster
    selected = Enum.find(socket.assigns.incidents, fn i -> i.id == inc_id end)

    if selected do
      incident = %{
        socket.assigns.incident
        | run_id: "RUN-" <> selected.id,
          work_order: selected.id,
          trade: selected.trade,
          client_nte: selected.nte_cap,
          sub_quote: selected.sub_quote,
          hazard_z: selected.z_score,
          sla_runway_minutes: selected.sla_remaining_min
      }

      {:noreply,
       socket
       |> assign(:selected_incident_id, inc_id)
       |> assign(:incident, incident)
       |> assign(:last_status_msg, "Switched active incident to #{inc_id} (#{selected.title})")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("adjust_nte", %{"nte" => nte_str}, socket) do
    nte = String.to_integer(nte_str)
    incident = %{socket.assigns.incident | client_nte: nte}
    quote_val = incident.sub_quote

    # Evaluate margin invariant
    case EngineBridge.bump_nte(
           socket.assigns.store,
           incident.run_id,
           nte,
           quote_val,
           incident.floor_pct
         ) do
      {:ok, _result} ->
        steps = advance_step_status(incident.steps, "diagnose", :completed)
        incident = %{incident | steps: steps}
        tape = EngineBridge.get_run_tape(socket.assigns.store, incident.run_id)

        {:noreply,
         socket
         |> assign(:incident, incident)
         |> assign(:tape, tape)
         |> assign(:last_status_msg, "NTE BUMP COMMITTED: $#{nte}")}

      {:error, {:refusal, :margin_invariant_breach, _details}} ->
        steps = advance_step_status(incident.steps, "diagnose", :blocked)
        incident = %{incident | steps: steps}

        {:noreply,
         socket
         |> assign(:incident, incident)
         |> assign(:last_status_msg, "REFUSED: Margin below 22% floor!")}
    end
  end

  def handle_event("select_scenario", %{"scenario" => scenario_str}, socket) do
    scenario = String.to_existing_atom(scenario_str)
    incident = ScenarioRunner.default_incident(scenario)
    {:ok, _record} = EngineBridge.start_scenario(socket.assigns.store, scenario, incident.run_id)
    tape = EngineBridge.get_run_tape(socket.assigns.store, incident.run_id)

    {:noreply,
     socket
     |> assign(:selected_scenario, scenario)
     |> assign(:incident, incident)
     |> assign(:tape, tape)
     |> assign(:last_status_msg, "Switched scenario: #{scenario}")}
  end

  def handle_event("quick_signal", %{"action" => "confirmed_driving"}, socket) do
    run_id = socket.assigns.incident.run_id

    # Emit signal extending hazard timer and returning step to active
    {:ok, _} =
      EngineBridge.resume_gate(socket.assigns.store, run_id, :gate_approved, %{
        status: :confirmed_driving,
        extend_minutes: 15
      })

    steps = advance_step_status(socket.assigns.incident.steps, "ack", :completed)
    steps = advance_step_status(steps, "arrive", :active)
    incident = %{socket.assigns.incident | hazard_z: 1.2, steps: steps}

    {:noreply,
     socket
     |> assign(:incident, incident)
     |> assign(:last_status_msg, "Confirmed driving. Hazard timer reset.")}
  end

  def handle_event("quick_signal", %{"action" => "emergency_detour"}, socket) do
    run_id = socket.assigns.incident.run_id
    {:ok, _} = EngineBridge.synthesize_detour(socket.assigns.store, run_id)
    incident = ScenarioRunner.default_incident(:contingency_detour)

    {:noreply,
     socket
     |> assign(:selected_scenario, :contingency_detour)
     |> assign(:incident, incident)
     |> assign(:last_status_msg, "FOND Detour activated. Re-routed to Tier-2 vendor.")}
  end

  def handle_event("quick_signal", %{"action" => "queue_secondary"}, socket) do
    {:noreply, assign(socket, :last_status_msg, "Secondary subcontractor queued.")}
  end

  def handle_event(
        "emit_engine_signal",
        %{"run_id" => run_id, "label" => label, "payload" => payload},
        socket
      ) do
    case EngineBridge.resume_gate(socket.assigns.store, run_id, label, payload) do
      {:ok, _} ->
        steps = advance_step_status(socket.assigns.incident.steps, to_string(label), :completed)
        incident = %{socket.assigns.incident | steps: steps}
        tape = EngineBridge.get_run_tape(socket.assigns.store, run_id)

        {:noreply,
         socket
         |> assign(:incident, incident)
         |> assign(:tape, tape)
         |> assign(:last_status_msg, "Signal #{label} processed.")}

      {:error, reason} ->
        {:noreply, assign(socket, :last_status_msg, "Signal error: #{inspect(reason)}")}
    end
  end

  # -- CAD Actions -------------------------------------------------------------

  @impl true
  def handle_info({:cad_action, :bump_nte, wo_id, %{nte: amount}}, socket) do
    # Target wo_id mapped to active run_id
    run_id = socket.assigns.incident.run_id
    quote_val = socket.assigns.incident.sub_quote

    case EngineBridge.bump_nte(
           socket.assigns.store,
           run_id,
           amount,
           quote_val,
           socket.assigns.incident.floor_pct
         ) do
      {:ok, _} ->
        steps = advance_step_status(socket.assigns.incident.steps, "diagnose", :completed)
        incident = %{socket.assigns.incident | client_nte: amount, steps: steps}
        tape = EngineBridge.get_run_tape(socket.assigns.store, run_id)

        {:noreply,
         socket
         |> assign(:incident, incident)
         |> assign(:tape, tape)
         |> assign(:last_status_msg, "CAD: NTE updated to $#{amount} for #{wo_id}")}

      {:error, {:refusal, :margin_invariant_breach, _}} ->
        steps = advance_step_status(socket.assigns.incident.steps, "diagnose", :blocked)
        incident = %{socket.assigns.incident | client_nte: amount, steps: steps}

        {:noreply,
         socket
         |> assign(:incident, incident)
         |> assign(:last_status_msg, "CAD REFUSAL: NTE $#{amount} breaches 22% margin floor!")}
    end
  end

  def handle_info({:cad_action, :dispatch, wo_id, %{vendor: vendor_id}}, socket) do
    {:noreply, assign(socket, :last_status_msg, "CAD: Dispatched #{wo_id} -> #{vendor_id}")}
  end

  def handle_info({:cad_action, :detour, _wo_id}, socket) do
    handle_event("quick_signal", %{"action" => "emergency_detour"}, socket)
  end

  def handle_info({:cad_action, :reset, _, _}, socket) do
    incident = ScenarioRunner.default_incident(:sub_hazard_drift)
    {:noreply, assign(socket, :incident, incident)}
  end

  def handle_info({:cad_action, :crash, _, _}, socket) do
    # Simulates crash by stopping store and restarting it from persistence
    if store = socket.assigns[:store] do
      GenServer.stop(store, :normal)
    end

    {:ok, new_store} = Ets.start_link()

    {:ok, _} =
      EngineBridge.start_scenario(
        new_store,
        socket.assigns.selected_scenario,
        socket.assigns.incident.run_id
      )

    {:noreply,
     socket
     |> assign(:store, new_store)
     |> assign(:last_status_msg, "CRASH SIMULATED: Store restarted, run state recovered intact.")}
  end

  # -- Telemetry Updates -------------------------------------------------------

  def handle_info(
        {:telemetry_tick, %{event: :hive_tick, tick: tick, incidents: incidents, log: log}},
        socket
      ) do
    # Rolling 35-item log tape
    updated_logs = [log | Enum.take(socket.assigns.logs, 34)]

    # Keep active incident updated with fresh z_score and sla countdown if matched
    active_inc =
      if selected = Enum.find(incidents, fn i -> i.id == socket.assigns.selected_incident_id end) do
        %{
          socket.assigns.incident
          | hazard_z: selected.z_score,
            sla_runway_minutes: selected.sla_remaining_min
        }
      else
        socket.assigns.incident
      end

    {:noreply,
     socket
     |> assign(:tick_count, tick)
     |> assign(:incidents, incidents)
     |> assign(:incident, active_inc)
     |> assign(:logs, updated_logs)
     |> push_event("hive_telemetry_tick", %{tick: tick, log: log})}
  end

  def handle_info(
        {:telemetry_tick, %{event: :anomaly_injected, incident_id: _inc_id, log: log}},
        socket
      ) do
    updated_logs = [log | Enum.take(socket.assigns.logs, 34)]
    {:noreply, assign(socket, :logs, updated_logs)}
  end

  def handle_info({:telemetry_tick, payload}, socket) do
    # Pushes live event to client hook
    {:noreply, push_event(socket, "telemetry_update", payload)}
  end

  def handle_info({:checkpoint_committed, cp}, socket) do
    tape = [cp | socket.assigns.tape]

    {:noreply,
     socket
     |> assign(:tape, tape)
     |> push_event("tape_append", cp)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # -- Helpers -----------------------------------------------------------------

  defp advance_step_status(steps, step_id, new_status) do
    Enum.map(steps, fn step ->
      if step.id == step_id or String.contains?(to_string(step.id), to_string(step_id)) do
        Map.put(step, :status, new_status)
      else
        step
      end
    end)
  end
end
