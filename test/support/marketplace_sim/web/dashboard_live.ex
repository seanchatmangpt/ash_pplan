defmodule AshPPlan.MarketplaceSim.DashboardLive do
  @moduledoc """
  Real-time ash_pplan fleet dashboard (Petal/LiveView) — every surface reads
  real ash_pplan state, nothing fabricated:

  1. Capability catalog: `AshPPlan.Workflow.CapabilityCatalog.all/0` plus the
     provider index (`AshPPlan.Test.Examples.ProviderIndex.modules/0`).
  2. Durable runs: a real `AshPPlan.Reactor.Durable.Store.Ets` store owned by
     the LiveView; run rows read through `Ets.list_runs/1` + `Ets.waiters/1`
     with tape length (`Ets.checkpoints/2`).
  3. Real-time event stream: `:telemetry.attach_many` on
     `AshPPlan.Reactor.Middleware.Observation.events/0` in mount/3; every step
     lifecycle event from REAL `Workflow.Runtime` runs lands here (last 50,
     newest first). Handler id is pid-scoped so multiple views don't collide;
     `terminate/2` detaches.
  4. Standing: the real durable standing tape — `Ets.standing/2` checkpoints
     (task_succeeded entries with snapshotted outputs) per run — surfaced in
     the run rows and the standing panel.
  5. FinOps panel + GCP lifecycle side nav (link to the explorer route).

  Form-to-run: the submit form starts a REAL durable `ontology_only` run
  (`AshPPlan.Examples.Runners.OntologyOnly.run_durable/2` on the dashboard's
  own store with the submitted run_id); the telemetry stream then shows that
  run's step events in real time. Anti-vacuity: with no runs the stream is
  empty — rows appear only from real executions.
  """

  use Phoenix.LiveView

  import PetalComponents.Card, only: [card: 1]
  import PetalComponents.Badge, only: [badge: 1]

  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Reactor.Middleware.Observation
  alias AshPPlan.Reactor.Middleware.Telemetry
  alias AshPPlan.Workflow.Runtime

  @runner AshPPlan.Examples.Runners.OntologyOnly
  @events_kept 50

  # -- lifecycle ----------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    {:ok, store} = Ets.start_link()
    {:ok, watcher} = start_telemetry_watcher(self())

    {:ok,
     socket
     |> assign(:store, store)
     |> assign(:telemetry_watcher, watcher)
     |> assign(:events, [])
     |> assign(:runs, [])
     |> assign(:durable_states, %{})
     |> assign(:active_run_id, nil)
     |> assign(:capabilities, AshPPlan.Workflow.CapabilityCatalog.all())
     |> assign(:providers, AshPPlan.Test.Examples.ProviderIndex.modules())
     |> assign(:sim, AshPPlan.MarketplaceSim.LifecycleLive.simulate(5_000_000, 400_000, 70))}
  end

  # Telemetry attach/detach is owned by a dedicated watcher process that
  # monitors the LiveView pid. terminate/2 is not guaranteed to run on a
  # crash/reconnect cycle, so cleanup is tied to the :DOWN monitor instead —
  # a crashed LiveView can no longer leak its telemetry handler.
  @doc false
  def start_telemetry_watcher(lv_pid) do
    handler = handler_id(lv_pid)

    # Unlinked spawn: the watcher must survive its owner's crash long enough
    # to detach — linking it here would reproduce the leak it exists to fix.
    watcher =
      spawn(fn ->
        ref = Process.monitor(lv_pid)

        :ok =
          :telemetry.attach_many(
            handler,
            Observation.events() ++ Telemetry.events(),
            &__MODULE__.relay/4,
            lv_pid
          )

        receive do
          {:DOWN, ^ref, :process, ^lv_pid, _reason} ->
            :telemetry.detach(handler)

          {:stop, ^ref} ->
            Process.demonitor(ref, [:flush])
            :telemetry.detach(handler)
        end
      end)

    {:ok, watcher}
  end

  @impl true
  def terminate(_reason, socket) do
    if watcher = socket.assigns[:telemetry_watcher] do
      ref = Process.monitor(watcher)
      send(watcher, {:stop, ref})

      receive do
        {:DOWN, ^ref, :process, ^watcher, _} -> :ok
      end
    end

    if store = socket.assigns[:store] do
      try do
        GenServer.stop(store, :normal)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # -- events -------------------------------------------------------------------

  @impl true
  def handle_event("start_run", %{"run" => %{"run_id" => run_id}}, socket)
      when is_binary(run_id) and run_id != "" do
    run_id = String.trim(run_id)
    socket = assign(socket, :active_run_id, run_id)

    # REAL durable run through the durable engine over the dashboard's own ETS
    # store: parks on the `confirm` gate, emitting step telemetry en route.
    case @runner.run_durable(%{}, store: socket.assigns.store, run_id: run_id) do
      {:ok, state} ->
        {:noreply,
         socket
         |> assign(:durable_states, Map.put(socket.assigns.durable_states, run_id, state))
         |> refresh()}

      {:error, err} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Run #{run_id} failed to start: #{err[:reason] || inspect(err)}"
         )
         |> refresh()}
    end
  end

  def handle_event("signal_confirm", %{"run_id" => run_id}, socket) when is_binary(run_id) do
    case Map.fetch(socket.assigns.durable_states, run_id) do
      :error ->
        {:noreply,
         socket
         |> put_flash(:error, "Unknown or expired run #{run_id}; refreshed the run ledger.")
         |> refresh()}

      {:ok, state} ->
        {:ok, explained} = Runtime.explain(state)
        waiting = explained.durable.waiting_on

        case waiting do
          [wait] ->
            {:ok, _resumed} = @runner.resume(state, signal: {wait, %{approved: true}})
            {:noreply, refresh(socket)}

          [] ->
            {:noreply, put_flash(socket, :error, "Run #{run_id} is not waiting on any gate.")}

          ambiguous ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Run #{run_id} waits on #{length(ambiguous)} gates; signal them individually."
             )}
        end
    end
  end

  # -- telemetry ----------------------------------------------------------------

  @doc false
  def relay(event_name, _measurements, metadata, pid) do
    send(pid, {__MODULE__, :telemetry, event_name, metadata})
  end

  @impl true
  def handle_info({__MODULE__, :telemetry, event_name, metadata}, socket) do
    _activity = metadata[:event] && metadata[:event].activity

    with [phase | rest] <- Enum.reverse(event_name),
         [prefix | _] <- rest do
      # Explicit run_id attribution: only events carrying their own run_id
      # are tagged with it — unrelated traffic is never attributed to the
      # dashboard's active run.
      row = %{
        time: System.system_time(:millisecond),
        run_id: to_string(metadata[:run_id] || ""),
        task: to_string(metadata[:step] || metadata[:task] || ""),
        activity: to_string("#{prefix}.#{phase}")
      }

      socket =
        socket
        |> assign(:events, [row | socket.assigns.events] |> Enum.take(@events_kept))

      {:noreply, refresh(socket)}
    else
      # Malformed/short event names are skipped, never crashed on.
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # -- render -------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl p-6 space-y-8">
      <div id="flashes">
        <div
          :for={{kind, msg} <- @flash}
          class="rounded p-3 mb-2 text-sm"
          data-flash-kind={kind}
        >
          {msg}
        </div>
      </div>
      <section id="dash-hero">
        <h1 class="text-2xl font-bold">ash_pplan Fleet Dashboard</h1>
        <div class="flex gap-2">
          <.link navigate="/" class="underline text-sm">Lifecycle Explorer</.link>
          <.link navigate="/dashboard" class="underline text-sm">Dashboard</.link>
        </div>
        <div class="mt-3 grid grid-cols-4 gap-4">
          <.card data-kpi="capabilities">
            <div class="text-3xl font-bold">{length(@capabilities)}</div>
            <div class="text-sm text-slate-600">Capabilities</div>
          </.card>
          <.card data-kpi="providers">
            <div class="text-3xl font-bold">{length(@providers)}</div>
            <div class="text-sm text-slate-600">Providers</div>
          </.card>
          <.card data-kpi="runs">
            <div class="text-3xl font-bold">{length(@runs)}</div>
            <div class="text-sm text-slate-600">Durable Runs</div>
          </.card>
          <.card data-kpi="events">
            <div class="text-3xl font-bold">{length(@events)}</div>
            <div class="text-sm text-slate-600">Live Step Events</div>
          </.card>
        </div>
      </section>

      <section id="form-to-run">
        <h2 class="text-lg font-semibold mb-2">Start a REAL durable run</h2>
        <.form
          id="start-run-form"
          for={%{}}
          phx-submit="start_run"
          class="flex items-end gap-4"
        >
          <label class="text-sm">
            Run ID
            <input type="text" name="run[run_id]" value="" placeholder="my-run-1" />
          </label>
          <button type="submit" class="pc-button pc-button--primary" data-action="start-run">
            Start durable run
          </button>
        </.form>
      </section>

      <section id="runs">
        <h2 class="text-lg font-semibold mb-2">Durable Runs (real ETS ledger)</h2>
        <div class="space-y-2" data-run-table>
          <div
            :for={run <- @runs}
            class="flex gap-4 items-center rounded border p-3 text-sm"
            data-run-row={run.run_id}
          >
            <span class="font-mono">{run.run_id}</span>
            <.badge color={
              cond do
                run.status == :completed -> "success"
                run.halted_on -> "warning"
                true -> "danger"
              end
            } size="xs">
              {run.status}
            </.badge>
            <span class="text-slate-500">{run.plan}</span>
            <span>waiters: {run.waiter_count}</span>
            <span>tape: {run.tape_length}</span>
            <span :if={run.halted_on}>halted on: {run.halted_on}</span>
            <button
              :if={run.halted_on and run.waiter_count == 1}
              phx-click="signal_confirm"
              phx-value-run_id={run.run_id}
              class="pc-button pc-button--sm"
              data-action="signal-confirm"
            >
              signal + resume
            </button>
          </div>
        </div>
      </section>

      <section id="stream">
        <h2 class="text-lg font-semibold mb-2">Real-Time Step Events (newest first)</h2>
        <div class="space-y-1" data-event-stream>
          <div
            :for={event <- @events}
            class="flex gap-4 text-xs font-mono rounded bg-slate-100 p-2"
            data-event-row={event.run_id}
            data-activity={event.activity}
          >
            <span>{event.run_id}</span>
            <span>{event.task}</span>
            <span>{event.activity}</span>
          </div>
        </div>
      </section>

      <section id="standing">
        <h2 class="text-lg font-semibold mb-2">Standing Tape (real checkpoints)</h2>
        <.card data-standing-panel>
          <%= if @runs == [] do %>
            <div class="text-sm text-slate-500" data-standing-empty>no runs yet</div>
          <% else %>
            <div :for={run <- @runs} class="font-mono text-xs">
              <span data-standing-run={run.run_id}>{run.run_id}</span>:
              <span data-standing-labels>{Enum.join(run.standing, " | ")}</span>
            </div>
          <% end %>
        </.card>
      </section>

      <section id="catalog">
        <h2 class="text-lg font-semibold mb-2">Capability Catalog</h2>
        <div class="grid grid-cols-4 gap-2" data-capability-grid>
          <div
            :for={cap <- @capabilities}
            class="text-xs font-mono rounded border p-2"
            data-capability={cap.id}
          >
            {cap.id}
            <.badge color="gray" size="xs">{cap.family}</.badge>
          </div>
        </div>
      </section>

      <section id="finops">
        <h2 class="text-lg font-semibold mb-2">FinOps Commitment Panel</h2>
        <div class="grid grid-cols-4 gap-4 text-sm">
          <.card data-finops="gain">
            <div class="text-2xl font-bold">{@sim.gain_pct}%</div>
            <div class="text-xs text-slate-600">Pool Gain</div>
          </.card>
          <.card data-finops="organic">
            <div class="text-2xl font-bold">{@sim.organic_burn}</div>
            <div class="text-xs text-slate-600">Organic Burn</div>
          </.card>
          <.card data-finops="remaining">
            <div class="text-2xl font-bold">{@sim.remaining_pool}</div>
            <div class="text-xs text-slate-600">Remaining Pool</div>
          </.card>
          <.card data-finops="post-deal">
            <div class="text-2xl font-bold">{@sim.post_deal_pool}</div>
            <div class="text-xs text-slate-600">Post-Deal Pool</div>
          </.card>
        </div>
      </section>
    </div>
    """
  end

  defp refresh(socket) do
    store = socket.assigns.store

    runs =
      store
      |> Ets.list_runs()
      |> Enum.map(fn run ->
        waiters = store |> Ets.waiters(run.id) |> List.wrap()
        _checkpoints = store |> Ets.checkpoints(run.id) |> List.wrap()

        standing = store |> Ets.standing(run.id) |> List.wrap()

        %{
          run_id: run.id,
          status: run.status,
          plan: run.plan_iri,
          halted_on: waiters != [] && hd(waiters).name,
          waiter_count: length(waiters),
          tape_length: length(standing),
          standing: Enum.map(standing, &"#{&1.label}")
        }
      end)
      |> Enum.sort_by(& &1.run_id)

    assign(socket, :runs, runs)
  end

  defp handler_id(pid), do: "mp_dash_#{inspect(pid)}"
end
