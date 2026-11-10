defmodule AshPPlan.Playground.HiveSimulator do
  @moduledoc """
  Autonomous background telemetry generator and fleet clock.
  Simulates a real-time hive of activity across industrial assets:
  - 1,000ms SLA countdown decrements
  - Dynamic telemetry fluctuations (pressures, temperatures, voltages, GPS)
  - Broadcasts to the playground telemetry topics ("cop:telemetry" and "cop:incidents")
  - Generates scrolling audit events and sensor anomalies
  """
  use GenServer

  alias AshPPlan.Playground.{ScenarioRunner, TelemetryBroadcaster}

  @tick_interval_ms 1000

  @pubsub AshPPlan.Playground.PubSub

  # Client API
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  def inject_anomaly(incident_id, anomaly_type) do
    GenServer.cast(__MODULE__, {:inject_anomaly, incident_id, anomaly_type})
  end

  # Server Callbacks
  @impl true
  def init(_opts) do
    roster =
      ScenarioRunner.multi_incident_roster()
      |> Enum.map(&normalize_incident/1)

    timer_ref = :timer.send_interval(@tick_interval_ms, self(), :tick)

    state = %{
      incidents: roster,
      timer_ref: timer_ref,
      tick_count: 0,
      active_sensors: init_sensor_pool()
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:inject_anomaly, incident_id, anomaly_type}, state) do
    updated_incidents =
      Enum.map(state.incidents, fn incident ->
        inc_id = Map.get(incident, :id) || Map.get(incident, :run_id)

        if inc_id == incident_id do
          incident
          |> Map.put(:hazard_z, 3.8)
          |> Map.put(:z_score, 3.8)
          |> Map.put(:status, "CRITICAL_ESCALATION")
        else
          incident
        end
      end)

    log_event = %{
      id: "LOG-" <> Integer.to_string(System.unique_integer([:positive])),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      level: "ALERT",
      subsystem: "SURGE_ANOMALY",
      message: "[MANUAL OVERRIDE] #{incident_id} tripped anomaly: #{anomaly_type} (Z=3.8)"
    }

    TelemetryBroadcaster.broadcast_telemetry(@pubsub, %{
      event: :anomaly_injected,
      incident_id: incident_id,
      log: log_event
    })

    {:noreply, %{state | incidents: updated_incidents}}
  end

  @impl true
  def handle_info(:tick, state) do
    new_tick = state.tick_count + 1

    # Decrement SLA, jitter telemetry, update incidents
    updated_incidents =
      Enum.map(state.incidents, fn inc ->
        decrement = if rem(new_tick, 5) == 0, do: 1, else: 0
        curr_sla = Map.get(inc, :sla_runway_minutes) || Map.get(inc, :sla_remaining_min) || 60
        new_sla = max(1, curr_sla - decrement)

        # Micro-fluctuations in z-score
        curr_z = Map.get(inc, :hazard_z) || Map.get(inc, :z_score) || 1.0
        jitter = (:rand.uniform(21) - 11) / 100.0
        new_z = Float.round(max(0.2, curr_z + jitter), 2)

        inc
        |> Map.put(:sla_runway_minutes, new_sla)
        |> Map.put(:sla_remaining_min, new_sla)
        |> Map.put(:hazard_z, new_z)
        |> Map.put(:z_score, new_z)
      end)

    # Generate streaming log event
    log_event = generate_hive_log_event(new_tick, updated_incidents)

    # Broadcast hive tick
    TelemetryBroadcaster.broadcast_telemetry(@pubsub, %{
      event: :hive_tick,
      tick: new_tick,
      incidents: updated_incidents,
      log: log_event
    })

    {:noreply, %{state | tick_count: new_tick, incidents: updated_incidents}}
  end

  # Internal Helpers
  defp normalize_incident(inc) do
    id = Map.get(inc, :run_id) || Map.get(inc, :id) || "INC-1"
    sla = Map.get(inc, :sla_runway_minutes) || Map.get(inc, :sla_remaining_min) || 60
    z = Map.get(inc, :hazard_z) || Map.get(inc, :z_score) || 1.0
    title = Map.get(inc, :work_order) || Map.get(inc, :title) || id
    asset = Map.get(inc, :site) || Map.get(inc, :asset_id) || "SITE-1"
    nte = Map.get(inc, :client_nte) || Map.get(inc, :nte_cap) || 1000

    inc
    |> Map.put(:id, id)
    |> Map.put(:run_id, id)
    |> Map.put(:sla_remaining_min, sla)
    |> Map.put(:sla_runway_minutes, sla)
    |> Map.put(:hazard_z, z)
    |> Map.put(:z_score, z)
    |> Map.put(:title, title)
    |> Map.put(:work_order, title)
    |> Map.put(:asset_id, asset)
    |> Map.put(:client_nte, nte)
    |> Map.put(:nte_cap, nte)
  end

  defp init_sensor_pool do
    [
      {"RACK-4B", :suction_psi, 42.0},
      {"SUB-02", :phase_voltage, 480.2},
      {"CRANE-01", :wind_speed_kts, 14.5},
      {"VALVE-NH3", :ambient_ppm, 8.2},
      {"BOILER-01", :firing_rate_pct, 68.0}
    ]
  end

  defp generate_hive_log_event(tick, incidents) do
    active_inc = Enum.random(incidents)
    levels = ["INFO", "TELEMETRY", "HEARTBEAT", "WARN"]
    subsystems = ["SAMSARA_GPS", "MODBUS_POLL", "HONEYWELL_BMS", "CORRIGO_SYNC", "PROV_AUDIT"]

    inc_id = Map.get(active_inc, :id) || Map.get(active_inc, :run_id) || "WO"
    asset = Map.get(active_inc, :asset_id) || Map.get(active_inc, :site) || "ASSET-1"
    sla = Map.get(active_inc, :sla_runway_minutes) || Map.get(active_inc, :sla_remaining_min) || 45
    nte = Map.get(active_inc, :client_nte) || Map.get(active_inc, :nte_cap) || 1000

    messages = [
      "Asset #{asset} Modbus poll OK: Delta T: +0.4°C, ΔP: 2.1 psi",
      "Worker GPS geo-fence verified: ETA #{max(2, sla - 3)}m",
      "Carrier certificate SHA-256 verified against State DB: VALID",
      "Thermal sensor drift -0.05% within allowable MIL-SPEC tolerance",
      "BMS ping response: 18ms latency across node cluster",
      "NTE check: Current committed $#{nte - 120} within limit $#{nte}"
    ]

    %{
      id: "TICK-#{tick}-" <> Integer.to_string(System.unique_integer([:positive])),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      level: Enum.at(levels, rem(tick, length(levels))),
      subsystem: Enum.at(subsystems, rem(tick, length(subsystems))),
      message: "[#{inc_id}] " <> Enum.random(messages)
    }
  end
end
