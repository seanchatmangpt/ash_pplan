defmodule AshPPlan.Playground.CopComponents do
  @moduledoc """
  Functional Phoenix component library for the Tactical Common Operating Picture (COP).
  Provides the visual primitives:
  - `.plan_delta_tape`: Dual-track IAP vs. COP timeline with Z-score hazard tags.
  - `.margin_invariant_envelope`: Real-time gross margin calculator with 22% floor.
  - `.force_readiness_gauge`: Subcontractor digital twin status and credential cards.
  - `.triage_incident_card`: Proactive intervention card for stalled field operations.
  """

  use Phoenix.Component

  # -- Plan Delta Tape ---------------------------------------------------------

  attr :run_id, :string, required: true
  attr :steps, :list, required: true
  attr :hazard_z, :float, default: 0.0

  def plan_delta_tape(assigns) do
    ~H"""
    <div id="plan-delta-tape" class="bg-zinc-950 border border-zinc-800 rounded-lg p-3 font-mono text-xs">
      <div class="flex items-center justify-between pb-2 border-b border-zinc-800 mb-2">
        <span class="text-zinc-400">
          INCIDENT FLIGHT TAPE: <strong class="text-zinc-100">{@run_id}</strong>
        </span>
        <span
          id="hazard-z-badge"
          data-hazard-z={@hazard_z}
          class={[
            "px-2 py-0.5 rounded text-[10px] font-bold tracking-wider uppercase",
            @hazard_z >= 2.5 && "bg-rose-950 text-rose-400 border border-rose-800 animate-pulse",
            @hazard_z >= 1.5 && @hazard_z < 2.5 && "bg-amber-950 text-amber-400 border border-amber-800",
            @hazard_z < 1.5 && "bg-emerald-950 text-emerald-400 border border-emerald-800"
          ]}
        >
          Z-SCORE: {@hazard_z}σ
        </span>
      </div>

      <div class="grid grid-flow-col auto-cols-fr gap-2 relative">
        <%= for step <- @steps do %>
          <div
            data-step-id={step.id}
            data-step-status={step.status}
            class={[
              "p-2 rounded border transition-colors",
              step.status == :completed && "bg-emerald-950/40 border-emerald-700/60 text-emerald-200",
              step.status == :drift && "bg-amber-950/50 border-amber-600 text-amber-300 animate-pulse",
              step.status == :blocked && "bg-rose-950/60 border-rose-650 text-rose-200",
              step.status == :active && "bg-cyan-950/50 border-cyan-500 text-cyan-200 animate-pulse",
              step.status == :unadmitted && "bg-zinc-900 border-zinc-800 text-zinc-600 border-dashed"
            ]}
          >
            <div class="flex justify-between items-center text-[10px] text-zinc-400">
              <span>{step.id}</span>
              <span>{step[:actual_t] || "--"}m / {step[:baseline_t]}m</span>
            </div>
            <div class="text-[11px] font-semibold truncate mt-1">
              {step[:label]}
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # -- Margin Invariant Envelope -----------------------------------------------

  attr :client_nte, :any, required: true
  attr :sub_quote, :any, required: true
  attr :floor_pct, :float, default: 22.0

  def margin_invariant_envelope(assigns) do
    nte = to_float(assigns.client_nte)
    quote_val = to_float(assigns.sub_quote)

    margin_pct =
      if nte > 0 do
        ((nte - quote_val) / nte) * 100.0
      else
        0.0
      end

    admitted? = margin_pct >= assigns.floor_pct

    assigns =
      assigns
      |> assign(:margin_pct, Float.round(margin_pct, 1))
      |> assign(:admitted?, admitted?)
      |> assign(:nte_val, nte)
      |> assign(:quote_val, quote_val)

    ~H"""
    <div id="margin-envelope-gauge" class="p-3 bg-zinc-950 border border-zinc-800 rounded font-mono text-xs">
      <div class="flex justify-between items-center mb-1">
        <span class="text-zinc-400">MARGIN ENVELOPE:</span>
        <span
          id="margin-status-tag"
          data-admitted={to_string(@admitted?)}
          class={[
            "font-bold",
            @admitted? && "text-emerald-400",
            !@admitted? && "text-rose-500 animate-pulse"
          ]}
        >
          {@margin_pct}% {if @admitted?, do: "[ADMITTED]", else: "[REFUSED]"}
        </span>
      </div>

      <!-- Visual progress bar with 22% floor cutoff line -->
      <div class="w-full bg-zinc-900 h-2 rounded relative overflow-hidden my-2 border border-zinc-800">
        <div
          class={if @admitted?, do: "bg-emerald-500 h-full", else: "bg-rose-500 h-full"}
          style={"width: #{min(max(@margin_pct, 0), 100)}%"}
        />
        <div
          class="absolute top-0 bottom-0 left-[22%] w-0.5 bg-zinc-300 opacity-70"
          title="22% Gross Margin Floor"
        />
      </div>

      <div class="flex justify-between text-[10px] text-zinc-500">
        <span>Quote: ${round(@quote_val)}</span>
        <span>Floor: {@floor_pct}%</span>
        <span>NTE: ${round(@nte_val)}</span>
      </div>
    </div>
    """
  end

  # -- Force Readiness Gauge ---------------------------------------------------

  attr :unit, :map, required: true

  def force_readiness_gauge(assigns) do
    ~H"""
    <div
      data-unit-id={@unit.id}
      class="p-3 bg-zinc-900 border border-zinc-800 rounded font-mono text-xs flex flex-col gap-2"
    >
      <div class="flex justify-between items-center">
        <div>
          <span class="font-bold text-zinc-100">{@unit.id}</span>
          <%= if @unit[:name] do %>
            <div class="text-[10px] text-zinc-400">{@unit.name}</div>
          <% end %>
        </div>
        <span class={[
          "text-[10px] px-1.5 py-0.5 rounded font-semibold uppercase",
          @unit.state == :on_scene && "bg-emerald-950 text-emerald-400 border border-emerald-800",
          @unit.state == :en_route && "bg-cyan-950 text-cyan-400 border border-cyan-800",
          @unit.state == :stalled && "bg-rose-950 text-rose-400 border border-rose-800 animate-pulse",
          @unit.state == :idle && "bg-zinc-800 text-zinc-400"
        ]}>
          {@unit.state}
        </span>
      </div>

      <div class="grid grid-cols-2 gap-x-2 text-[11px] text-zinc-400">
        <div>TRADE: <span class="text-zinc-200">{@unit.trade}</span></div>
        <div>ETA: <span class="text-zinc-200">{@unit.eta_minutes}m</span></div>
        <div class="flex items-center gap-1">
          COI:
          <span class={if @unit.coi_valid?, do: "text-emerald-400 font-bold", else: "text-rose-400 font-bold"}>
            {if @unit.coi_valid?, do: "VERIFIED", else: "EXPIRED"}
          </span>
        </div>
        <div>SCORE: <span class="text-zinc-200">{@unit.reliability_score}%</span></div>
      </div>
    </div>
    """
  end

  # -- Triage Intervention Card ------------------------------------------------

  attr :incident, :map, required: true

  def triage_incident_card(assigns) do
    ~H"""
    <div
      id="triage-intervention-card"
      class="bg-zinc-950 border border-rose-800/80 rounded-lg p-3 font-mono text-xs flex flex-col gap-2"
    >
      <div class="flex items-center justify-between pb-1 border-b border-rose-950">
        <span class="text-rose-400 font-bold flex items-center gap-1">
          ⚠️ PROACTIVE DISPATCH INTERVENTION REQUIRED
        </span>
        <span class="text-zinc-400 text-[10px]">
          SLA Runway: <strong class="text-rose-300">{@incident.sla_runway_minutes}m (Critical)</strong>
        </span>
      </div>

      <div class="text-[11px] text-zinc-300 space-y-1">
        <div><strong>Incident:</strong> {@incident.work_order} — {@incident.trade}</div>
        <%= if tech = @incident[:technician] do %>
          <div><strong>Assigned:</strong> {tech.vendor} | Tech: {tech.name} ({tech.phone})</div>
          <div class="text-amber-300">
            <strong>Anomaly:</strong> {tech.elapsed_minutes}m elapsed since dispatch (Baseline: {tech.median_latency}m ± {tech.mad}m, Z = +{@incident.hazard_z}σ).
          </div>
        <% end %>
      </div>

      <div class="pt-2 flex flex-wrap gap-2">
        <button
          phx-click="quick_signal"
          phx-value-action="confirmed_driving"
          class="bg-cyan-900/80 hover:bg-cyan-800 text-cyan-200 px-2 py-1 rounded text-[10px] border border-cyan-700"
        >
          [ 1: Confirmed Driving (Extend 15m) ]
        </button>
        <button
          phx-click="quick_signal"
          phx-value-action="queue_secondary"
          class="bg-amber-900/80 hover:bg-amber-800 text-amber-200 px-2 py-1 rounded text-[10px] border border-amber-700"
        >
          [ 2: No Answer (Queue Secondary) ]
        </button>
        <button
          phx-click="quick_signal"
          phx-value-action="emergency_detour"
          class="bg-rose-900/80 hover:bg-rose-800 text-rose-200 px-2 py-1 rounded text-[10px] border border-rose-700"
        >
          [ 3: Tech Declined / FOND Detour ]
        </button>
      </div>
    </div>
    """
  end

  defp to_float(val) when is_float(val), do: val
  defp to_float(val) when is_integer(val), do: val * 1.0

  defp to_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0
end
