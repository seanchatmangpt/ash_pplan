defmodule AshPPlan.Playground.TelemetryBroadcaster do
  @moduledoc """
  PubSub-agnostic telemetry broadcaster for the Tactical COP Playground.

  Streams live twin updates, statistical hazard shifts, and durable checkpoint
  commits to subscribers (the COP LiveView frontend in test support).

  ## Delivery mechanism

  Delivery is OTP-stdlib `:pg` (default local scope, one group per topic) — no
  Phoenix PubSub anywhere in `lib/`. This keeps the playground surface
  runtime-pure: the module compiles and broadcasts in any OTP release without
  Phoenix on the load path.

  Message shapes are unchanged from the original PubSub wire format, so
  consumer `handle_info` clauses are untouched:

    * `{:telemetry_tick, payload}`
    * `{:checkpoint_committed, checkpoint}`
    * `{:hazard_alert, %{incident_id:, z_score:}}`

  The `pubsub` first argument on the arity-2 broadcast functions is retained
  for call-site compatibility and is ignored by `:pg` delivery.
  """

  @topic_telemetry "cop:telemetry"
  @topic_incidents "cop:incidents"

  @doc "Topic for telemetry pings and checkpoint commits."
  def topic_telemetry, do: @topic_telemetry

  @doc "Topic for incident-level status and triage promotions."
  def topic_incidents, do: @topic_incidents

  @doc """
  Subscribes the calling process to a playground topic. Idempotent.
  Returns `:ok`.
  """
  @spec subscribe(term()) :: :ok
  def subscribe(topic) do
    ensure_pg()
    :pg.join(topic, self())
    :ok
  end

  @doc "Removes the calling process's subscription to a topic. Returns `:ok`."
  @spec unsubscribe(term()) :: :ok
  def unsubscribe(topic) do
    ensure_pg()
    :pg.leave(topic, self())
    :ok
  end

  @doc """
  Broadcasts a real-time telemetry update (e.g. vehicle GPS, sensor ping,
  Z-score, hive tick log event).
  """
  @spec broadcast_telemetry(map()) :: :ok
  def broadcast_telemetry(payload) when is_map(payload) do
    do_broadcast(@topic_telemetry, {:telemetry_tick, payload})
  end

  @doc """
  Legacy call-compat head: the `pubsub` server argument is retained but
  ignored — delivery goes through the local `:pg` topic group.
  """
  @spec broadcast_telemetry(term(), map()) :: :ok
  def broadcast_telemetry(_pubsub, payload) when is_map(payload) do
    broadcast_telemetry(payload)
  end

  @doc """
  Broadcasts a newly committed durable checkpoint to the active run topic.
  """
  @spec broadcast_checkpoint(map()) :: :ok
  def broadcast_checkpoint(checkpoint) when is_map(checkpoint) do
    do_broadcast(@topic_telemetry, {:checkpoint_committed, checkpoint})
  end

  @doc "Legacy call-compat head (see `broadcast_telemetry/2`)."
  @spec broadcast_checkpoint(term(), map()) :: :ok
  def broadcast_checkpoint(_pubsub, checkpoint) when is_map(checkpoint) do
    broadcast_checkpoint(checkpoint)
  end

  @doc """
  Broadcasts an urgent proactive intervention alert when hazard Z >= 2.5.
  """
  @spec broadcast_hazard_alert(term(), number()) :: :ok
  def broadcast_hazard_alert(incident_id, z_score) do
    do_broadcast(
      @topic_incidents,
      {:hazard_alert, %{incident_id: incident_id, z_score: z_score}}
    )
  end

  @doc "Legacy call-compat head (see `broadcast_telemetry/2`)."
  @spec broadcast_hazard_alert(term(), term(), number()) :: :ok
  def broadcast_hazard_alert(_pubsub, incident_id, z_score) do
    broadcast_hazard_alert(incident_id, z_score)
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  # The :pg application is not always loadable (some OTP installs ship the
  # :pg module without pg.app on the code path), so ensure the default local
  # scope process is running directly. Unlinked (:pg.start/0, not start_link)
  # so the caller's lifecycle never kills the scope; idempotent under the
  # registered name :pg.
  defp ensure_pg do
    case Process.whereis(:pg) do
      nil ->
        case :pg.start(:pg) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} ->
            raise "playground telemetry broadcaster: :pg unavailable: #{inspect(reason)}"
        end

      _pid ->
        :ok
    end
  end

  defp do_broadcast(topic, message) do
    ensure_pg()

    case :pg.get_local_members(topic) do
      members when is_list(members) ->
        Enum.each(members, fn pid -> send(pid, message) end)
        :ok

      {:error, reason} ->
        {:error, {:broadcast_refused, :topic_group_unavailable, topic, reason}}
    end
  end
end
