defmodule AshPPlan.Playground.Layouts do
  @moduledoc false

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="dark h-full bg-black">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Tactical COP // ash_pplan Flight Deck</title>
        <script src="https://cdn.tailwindcss.com"></script>
        <script>
          tailwind.config = {
            darkMode: 'class',
            theme: {
              extend: {
                colors: {
                  zinc: {
                    850: '#1f1f23',
                    750: '#33333a',
                    650: '#4b4b55'
                  }
                }
              }
            }
          }
        </script>
        <script src="https://cdn.jsdelivr.net/npm/phoenix@1.7.14/priv/static/phoenix.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/phoenix_live_view@1.0.0/priv/static/phoenix_live_view.min.js"></script>
        <script>
          window.Hooks = {
            ReactFlowHook: {
              mounted() {
                this.render();
                this.handleEvent("tape_append", () => this.render());
              },
              updated() {
                this.render();
              },
              render() {
                const steps = this.el.dataset.steps ? JSON.parse(this.el.dataset.steps) : [];
                const runId = this.el.dataset.runId;
                let c = this.el.querySelector(".cop-dag-canvas");
                if (!c) {
                  c = document.createElement("div");
                  c.className = "cop-dag-canvas w-full h-full p-4 overflow-x-auto flex items-center gap-6";
                  this.el.innerHTML = "";
                  this.el.appendChild(c);
                }
                c.innerHTML = "";
                steps.forEach((step, idx) => {
                  const node = document.createElement("div");
                  const border = step.status === "completed" ? "bg-emerald-950/70 border-emerald-600 text-emerald-200" :
                    step.status === "drift" ? "bg-amber-950/70 border-amber-500 text-amber-200 animate-pulse" :
                    step.status === "blocked" ? "bg-rose-950/80 border-rose-600 text-rose-200" :
                    step.status === "active" ? "bg-cyan-950/70 border-cyan-500 text-cyan-200 animate-pulse" :
                    "bg-zinc-900 border-zinc-800 text-zinc-600 border-dashed";
                  node.className = "p-3 rounded border font-mono text-xs flex flex-col gap-1 min-w-[170px] " + border;
                  node.innerHTML = `
                    <div class="flex justify-between items-center text-[10px] text-zinc-400">
                      <span>#${idx + 1}</span><span class="uppercase font-bold">${step.status}</span>
                    </div>
                    <div class="font-bold text-zinc-100 truncate">${step.label || step.id}</div>
                    <div class="text-[10px] text-zinc-400">Baseline: ${step.baseline_t || "--"}m | Real: ${step.actual_t || "--"}m</div>
                  `;
                  if (step.status === "blocked" || step.status === "drift") {
                    const btn = document.createElement("button");
                    btn.className = "mt-2 bg-emerald-700 hover:bg-emerald-600 text-white px-2 py-0.5 rounded text-[10px] font-bold";
                    btn.innerText = "Release Gate";
                    btn.onclick = () => {
                      this.pushEvent("emit_engine_signal", { run_id: runId, label: step.id, payload: { approved: true } });
                    };
                    node.appendChild(btn);
                  }
                  c.appendChild(node);
                  if (idx < steps.length - 1) {
                    const a = document.createElement("div");
                    a.className = "text-zinc-650 font-bold select-none text-base";
                    a.innerText = "──►";
                    c.appendChild(a);
                  }
                });
              }
            },
            ScrubberHook: {
              mounted() {
                this.render();
                this.handleEvent("tape_append", () => this.render());
              },
              updated() {
                this.render();
              },
              render() {
                const tape = this.el.dataset.tape ? JSON.parse(this.el.dataset.tape) : [];
                this.el.innerHTML = `
                  <div class="w-full flex items-center justify-between font-mono text-[10px] text-zinc-400">
                    <div class="flex items-center gap-2">
                      <span class="text-emerald-400 font-bold">PLAYHEAD ▶</span>
                      <span>COMMITTED CHECKPOINTS: <strong>${tape.length}</strong></span>
                    </div>
                    <div class="flex items-center gap-1">
                      ${tape.map((cp, i) => `<span class="px-1.5 py-0.5 rounded bg-zinc-800 text-zinc-300 border border-zinc-700" title="${cp.label || cp.id}">#${cp.seq || i + 1}</span>`).join("")}
                    </div>
                  </div>
                `;
              }
            }
          };

          document.addEventListener("DOMContentLoaded", () => {
            const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
            if (window.LiveView && window.LiveView.LiveSocket) {
              const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
                params: { _csrf_token: csrfToken },
                hooks: window.Hooks
              });
              liveSocket.connect();
              window.liveSocket = liveSocket;
            }
          });
        </script>
      </head>
      <body class="h-full bg-black text-zinc-100 overflow-hidden">
        <%= @inner_content %>
      </body>
    </html>
    """
  end
end
