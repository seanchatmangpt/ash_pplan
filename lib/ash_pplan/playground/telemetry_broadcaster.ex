defmodule AshPPlan.Playground.TelemetryBroadcaster do
  @moduledoc """
  PubSub telemetry broadcaster for the Tactical COP Playground.
  Streams live twin updates, statistical hazard shifts, and durable checkpoint
  commits to the LiveView frontend.
  """

  @topic_telemetry "cop:telemetry"
  @topic_incidents "cop:incidents"

  @doc "PubSub topic for telemetry pings and checkpoint commits."
  def topic_telemetry, do: @topic_telemetry

  @doc "PubSub topic for incident-level status and triage promotions."
  def topic_incidents, do: @topic_incidents

  @doc """
  Broadcasts a real-time telemetry update (e.g. vehicle GPS, sensor ping, Z-score).
  """
  def broadcast_telemetry(pubsub, payload) do
    Phoenix.PubSub.broadcast(pubsub, @topic_telemetry, {:telemetry_tick, payload})
  end

  @doc """
  Broadcasts a newly committed durable checkpoint to the active run topic.
  """
  def broadcast_checkpoint(pubsub, checkpoint) do
    Phoenix.PubSub.broadcast(pubsub, @topic_telemetry, {:checkpoint_committed, checkpoint})
  end

  @doc """
  Broadcasts an urgent proactive intervention alert when hazard Z >= 2.5.
  """
  def broadcast_hazard_alert(pubsub, incident_id, z_score) do
    Phoenix.PubSub.broadcast(
      pubsub,
      @topic_incidents,
      {:hazard_alert, %{incident_id: incident_id, z_score: z_score}}
    )
  end
end
