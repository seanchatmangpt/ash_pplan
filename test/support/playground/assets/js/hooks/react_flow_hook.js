/**
 * ReactFlowHook: Bridges Phoenix LiveView to the @xyflow/react Causal DAG canvas.
 *
 * Supports:
 * - Ingestion of initial step topology from data-steps.
 * - Live step updates via "tape_append" server pushes.
 * - Outbound resumption signals via pushEvent("emit_engine_signal", ...).
 * - Full interactive fallback rendering when running standalone or in test mode.
 */

export const ReactFlowHook = {
  mounted() {
    this.runId = this.el.dataset.runId;
    this.steps = this.el.dataset.steps ? JSON.parse(this.el.dataset.steps) : [];

    this.renderCanvas();

    this.handleEvent("tape_append", (checkpoint) => {
      this.steps = this.steps.map((s) => {
        if (s.id === checkpoint.id || s.id === checkpoint.step_key) {
          return { ...s, status: "completed" };
        }
        return s;
      });
      this.renderCanvas();
    });

    this.handleEvent("telemetry_update", (telemetry) => {
      if (telemetry && telemetry.hazard_z) {
        this.hazardZ = telemetry.hazard_z;
        this.renderCanvas();
      }
    });
  },

  updated() {
    if (this.el.dataset.steps) {
      this.steps = JSON.parse(this.el.dataset.steps);
      this.renderCanvas();
    }
  },

  renderCanvas() {
    // If React & ReactFlow root exists, update React tree;
    // otherwise render the high-performance SVG/HTML interactive graph:
    let container = this.el.querySelector(".cop-dag-canvas");
    if (!container) {
      container = document.createElement("div");
      container.className = "cop-dag-canvas w-full h-full p-4 overflow-x-auto flex items-center gap-6";
      this.el.innerHTML = "";
      this.el.appendChild(container);
    }

    container.innerHTML = "";

    this.steps.forEach((step, idx) => {
      const node = document.createElement("div");
      node.className = `p-3 rounded border font-mono text-xs flex flex-col gap-1 min-w-[160px] transition-all ${
        step.status === "completed"
          ? "bg-emerald-950/70 border-emerald-600 text-emerald-200"
          : step.status === "drift"
          ? "bg-amber-950/70 border-amber-500 text-amber-200 animate-pulse"
          : step.status === "blocked"
          ? "bg-rose-950/80 border-rose-600 text-rose-200"
          : step.status === "active"
          ? "bg-cyan-950/70 border-cyan-500 text-cyan-200 animate-pulse"
          : "bg-zinc-900 border-zinc-800 text-zinc-600 border-dashed"
      }`;

      const header = document.createElement("div");
      header.className = "flex justify-between items-center text-[10px] text-zinc-400";
      header.innerHTML = `<span>#${idx + 1}</span><span class="uppercase font-bold">${step.status}</span>`;
      node.appendChild(header);

      const title = document.createElement("div");
      title.className = "font-bold text-zinc-100 truncate";
      title.innerText = step.label || step.id;
      node.appendChild(title);

      const time = document.createElement("div");
      time.className = "text-[10px] text-zinc-400";
      time.innerText = `Baseline: ${step.baseline_t || "--"}m | Real: ${step.actual_t || "--"}m`;
      node.appendChild(time);

      if (step.status === "blocked" || step.status === "drift") {
        const btn = document.createElement("button");
        btn.className = "mt-2 bg-emerald-700 hover:bg-emerald-600 text-white px-2 py-0.5 rounded text-[10px] font-bold";
        btn.innerText = "Release Gate";
        btn.onclick = () => {
          this.pushEvent("emit_engine_signal", {
            run_id: this.runId,
            label: step.id,
            payload: { approved: true, timestamp: new Date().toISOString() },
          });
        };
        node.appendChild(btn);
      }

      container.appendChild(node);

      if (idx < this.steps.length - 1) {
        const arrow = document.createElement("div");
        arrow.className = "text-zinc-650 font-bold select-none";
        arrow.innerText = "──►";
        container.appendChild(arrow);
      }
    });
  },
};
