defmodule AshPPlan.Playground.ScenarioRunner do
  @moduledoc """
  Pre-loaded operational test scenarios and Digital Twin data models for the
  Tactical Common Operating Picture (COP) Playground.

  Models:
  - Incident Action Plan (IAP) target milestones vs. COP real timestamps.
  - Multi-incident fleet roster running concurrently.
  - Subcontractor Twin latency distributions (median, MAD, and hazard Z-score).
  - Force readiness roster with trade licensing and COI certification status.
  """

  @doc """
  Returns a roster of 5 concurrent active operational incidents across municipalities.
  """
  def multi_incident_roster do
    [
      default_incident(:sub_hazard_drift),
      %{
        run_id: "rel-2",
        work_order: "WO-8924",
        site: "Site #108 (Oakland, CA)",
        trade: "480V Commercial Electrical",
        hazard_z: 0.92,
        client_nte: 2500,
        sub_quote: 1800,
        floor_pct: 22.0,
        sla_runway_minutes: 114,
        technician: %{
          name: "Carlos Reyes",
          phone: "555-0812",
          vendor: "Bay Area Electric C-10",
          median_latency: 22,
          mad: 5,
          elapsed_minutes: 24
        },
        steps: [
          %{id: "intake", label: "Work Order Intake", baseline_t: 5, actual_t: 4, status: :completed},
          %{id: "ack", label: "Master Electrician Ack", baseline_t: 20, actual_t: 18, status: :completed},
          %{id: "arrive", label: "Geofence Entry", baseline_t: 50, actual_t: 46, status: :completed},
          %{id: "diagnose", label: "Transformer Isolation", baseline_t: 90, actual_t: nil, status: :active},
          %{id: "reconcile", label: "City Permit Sign-off", baseline_t: 140, actual_t: nil, status: :unadmitted}
        ]
      },
      %{
        run_id: "rel-3",
        work_order: "WO-8928",
        site: "Site #305 (Chicago, IL)",
        trade: "Commercial HVAC (10-Ton Rooftop)",
        hazard_z: 1.45,
        client_nte: 4800,
        sub_quote: 3450,
        floor_pct: 22.0,
        sla_runway_minutes: 68,
        technician: %{
          name: "Elena Rostova",
          phone: "555-0399",
          vendor: "Windy City Mechanical",
          median_latency: 30,
          mad: 8,
          elapsed_minutes: 42
        },
        steps: [
          %{id: "intake", label: "Work Order Intake", baseline_t: 5, actual_t: 5, status: :completed},
          %{id: "permit", label: "City Crane Permit Gate", baseline_t: 25, actual_t: 22, status: :completed},
          %{id: "arrive", label: "Crane On Scene", baseline_t: 60, actual_t: 58, status: :completed},
          %{id: "hoist", label: "Compressor Lift", baseline_t: 100, actual_t: nil, status: :active},
          %{id: "reconcile", label: "Structural Load Verification", baseline_t: 160, actual_t: nil, status: :unadmitted}
        ]
      },
      %{
        run_id: "rel-4",
        work_order: "WO-8931",
        site: "Site #512 (Sacramento, CA)",
        trade: "Ammonia Cold Storage Safety",
        hazard_z: 0.38,
        client_nte: 1200,
        sub_quote: 850,
        floor_pct: 22.0,
        sla_runway_minutes: 175,
        technician: %{
          name: "Mark Henderson",
          phone: "555-0721",
          vendor: "NorCal Industrial",
          median_latency: 18,
          mad: 4,
          elapsed_minutes: 16
        },
        steps: [
          %{id: "intake", label: "Emergency Telemetry Tripped", baseline_t: 5, actual_t: 3, status: :completed},
          %{id: "ack", label: "Hazmat Tech Ack", baseline_t: 15, actual_t: 12, status: :completed},
          %{id: "arrive", label: "Ventilation Air-Gap Check", baseline_t: 35, actual_t: 31, status: :completed},
          %{id: "diagnose", label: "PPM Sensor Calibration", baseline_t: 60, actual_t: 55, status: :completed},
          %{id: "reconcile", label: "EPA 608 Level 4 Clearance", baseline_t: 90, actual_t: nil, status: :active}
        ]
      },
      %{
        run_id: "rel-5",
        work_order: "WO-8935",
        site: "Site #201 (San Francisco, CA)",
        trade: "Commercial Boiler Water Tube",
        hazard_z: 1.88,
        client_nte: 1000,
        sub_quote: 890,
        floor_pct: 22.0,
        sla_runway_minutes: 28,
        technician: %{
          name: "James Kelly",
          phone: "555-0455",
          vendor: "Pacific Boiler & Steam",
          median_latency: 20,
          mad: 5,
          elapsed_minutes: 29
        },
        steps: [
          %{id: "intake", label: "Work Order Intake", baseline_t: 5, actual_t: 4, status: :completed},
          %{id: "ack", label: "Boiler Tech Dispatch", baseline_t: 20, actual_t: 19, status: :completed},
          %{id: "arrive", label: "Basement Geofence Ping", baseline_t: 45, actual_t: 42, status: :completed},
          %{id: "diagnose", label: "Pressure Vessel Hydro-Test", baseline_t: 80, actual_t: 78, status: :blocked},
          %{id: "reconcile", label: "ASME Certificate Stamp", baseline_t: 130, actual_t: nil, status: :unadmitted}
        ]
      }
    ]
  end

  @doc """
  Returns an incident model by scenario type.
  """
  def default_incident(scenario \\ :sub_hazard_drift) do
    case scenario do
      :nominal ->
        %{
          run_id: "rel-1",
          work_order: "WO-8921",
          site: "Site #402 (San Jose, CA)",
          trade: "Commercial Refrigeration",
          hazard_z: 0.8,
          client_nte: 1400,
          sub_quote: 1000,
          floor_pct: 22.0,
          sla_runway_minutes: 95,
          steps: [
            %{id: "intake", label: "Work Order Intake", baseline_t: 5, actual_t: 4, status: :completed},
            %{id: "ack", label: "Subcontractor Ack", baseline_t: 15, actual_t: 12, status: :completed},
            %{id: "arrive", label: "Geofence Arrival", baseline_t: 45, actual_t: 40, status: :completed},
            %{id: "diagnose", label: "Diagnosis & Quote", baseline_t: 75, actual_t: nil, status: :active},
            %{id: "reconcile", label: "Final Billing & Sign-off", baseline_t: 120, actual_t: nil, status: :unadmitted}
          ]
        }

      :sub_hazard_drift ->
        %{
          run_id: "rel-1",
          work_order: "WO-8921",
          site: "Site #402 (San Jose, CA)",
          trade: "Commercial Refrigeration (Walk-in Cooler)",
          hazard_z: 2.81,
          client_nte: 1000,
          sub_quote: 750,
          floor_pct: 22.0,
          sla_runway_minutes: 42,
          technician: %{
            name: "Dave Miller",
            phone: "555-0143",
            vendor: "Apex Mechanical",
            median_latency: 14,
            mad: 4,
            elapsed_minutes: 38
          },
          steps: [
            %{id: "intake", label: "Work Order Intake", baseline_t: 5, actual_t: 4, status: :completed},
            %{id: "ack", label: "Subcontractor Ack", baseline_t: 15, actual_t: 38, status: :drift},
            %{id: "arrive", label: "Geofence Arrival", baseline_t: 45, actual_t: nil, status: :blocked},
            %{id: "diagnose", label: "Diagnosis & Quote", baseline_t: 75, actual_t: nil, status: :unadmitted},
            %{id: "reconcile", label: "Final Billing & Sign-off", baseline_t: 120, actual_t: nil, status: :unadmitted}
          ]
        }

      :margin_breach ->
        %{
          run_id: "rel-1",
          work_order: "WO-8921",
          site: "Site #402 (San Jose, CA)",
          trade: "Commercial Refrigeration",
          hazard_z: 1.2,
          client_nte: 1000,
          sub_quote: 880,
          floor_pct: 22.0,
          sla_runway_minutes: 60,
          steps: [
            %{id: "intake", label: "Work Order Intake", baseline_t: 5, actual_t: 5, status: :completed},
            %{id: "ack", label: "Subcontractor Ack", baseline_t: 15, actual_t: 14, status: :completed},
            %{id: "arrive", label: "Geofence Arrival", baseline_t: 45, actual_t: 42, status: :completed},
            %{id: "diagnose", label: "Scope & Quote Exceeded", baseline_t: 75, actual_t: 70, status: :blocked},
            %{id: "reconcile", label: "Final Billing & Sign-off", baseline_t: 120, actual_t: nil, status: :unadmitted}
          ]
        }

      :contingency_detour ->
        %{
          run_id: "rel-1",
          work_order: "WO-8921",
          site: "Site #402 (San Jose, CA)",
          trade: "Commercial Refrigeration",
          hazard_z: 0.5,
          client_nte: 1450,
          sub_quote: 1050,
          floor_pct: 22.0,
          sla_runway_minutes: 80,
          steps: [
            %{id: "intake", label: "Work Order Intake", baseline_t: 5, actual_t: 4, status: :completed},
            %{id: "ack", label: "Primary Sub Declined", baseline_t: 15, actual_t: 20, status: :completed},
            %{id: "detour", label: "Tier-2 Secondary Detour", baseline_t: 25, actual_t: 24, status: :completed},
            %{id: "arrive", label: "Secondary Geofence Arrival", baseline_t: 55, actual_t: 48, status: :completed},
            %{id: "diagnose", label: "Diagnosis & Quote", baseline_t: 85, actual_t: nil, status: :active}
          ]
        }
    end
  end

  @doc """
  Returns candidate subcontractor digital twin units with readiness status.
  """
  def default_units do
    [
      %{
        id: "APEX-104",
        name: "Apex Mechanical (Dave Miller)",
        trade: "HVAC C-20",
        coi_valid?: true,
        state: :stalled,
        eta_minutes: 24,
        reliability_score: 92
      },
      %{
        id: "STRATA-201",
        name: "Strata HVAC Solutions",
        trade: "HVAC C-20 / C-36",
        coi_valid?: true,
        state: :en_route,
        eta_minutes: 18,
        reliability_score: 96
      },
      %{
        id: "BAY-305",
        name: "Bay Area Facilities & Air",
        trade: "General Handyman (No C-20)",
        coi_valid?: false,
        state: :idle,
        eta_minutes: 12,
        reliability_score: 74
      },
      %{
        id: "GRID-411",
        name: "CalGrid High-Voltage Services",
        trade: "Electrical C-10",
        coi_valid?: true,
        state: :on_scene,
        eta_minutes: 0,
        reliability_score: 98
      }
    ]
  end

  @doc """
  Computes the statistical anomaly latency score (Z-Score):
  Z = (elapsed - median) / MAD
  """
  def calculate_hazard_z(elapsed, median, mad) when mad > 0 do
    Float.round((elapsed - median) / mad, 2)
  end

  def calculate_hazard_z(_elapsed, _median, _mad), do: 0.0
end
