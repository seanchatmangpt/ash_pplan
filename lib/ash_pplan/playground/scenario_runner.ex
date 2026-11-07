defmodule AshPPlan.Playground.ScenarioRunner do
  @moduledoc """
  Pre-loaded operational test scenarios and Digital Twin data models for the
  Tactical Common Operating Picture (COP) Playground.

  Models:
  - Incident Action Plan (IAP) target milestones vs. COP real timestamps.
  - Subcontractor Twin latency distributions (median, MAD, and hazard Z-score).
  - Force readiness roster with trade licensing and COI certification status.
  """

  @doc """
  Returns the active default incident model (e.g. #WO-8921 Walk-in Cooler).
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
