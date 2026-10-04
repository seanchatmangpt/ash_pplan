defmodule AshPPlan.Sim.Marketplace.Google.Pubsub do
  @moduledoc """
  In-process simulation of Google Cloud Pub/Sub: ordered per-topic fan-out
  to named subscriber processes.

  Envelopes are JSON-shaped maps: `%{id: monotonic_seq, "data" => base64(JSON),
  "publishTime" => given timestamp}`. Delivery is `GenServer.cast` to each
  subscriber; redeliveries per {subscriber, id} are counted and exposed via
  `redeliveries/1` so courts can simulate duplicate delivery.
  """

  use GenServer

  # -- client API --

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Publish a JSON-encodable payload to a topic at the given timestamp. Returns the assigned id."
  def publish(pubsub, topic, payload, publish_time) do
    GenServer.call(pubsub, {:publish, topic, payload, publish_time})
  end

  @doc "Subscribe a process (default: self) to a topic. Messages are cast to it."
  def subscribe(pubsub, topic, subscriber \\ self()) do
    GenServer.call(pubsub, {:subscribe, topic, subscriber})
  end

  @doc "Redeliver every envelope on the topic to a subscriber (duplicate-delivery simulation)."
  def redeliver(pubsub, topic, subscriber \\ self()) do
    GenServer.call(pubsub, {:redeliver, topic, subscriber})
  end

  @doc "Count of duplicate (redelivered) envelopes received per subscriber."
  def redeliveries(pubsub) do
    GenServer.call(pubsub, :redeliveries)
  end

  @doc "Drain all envelopes on a topic, oldest first."
  def drain(pubsub, topic) do
    GenServer.call(pubsub, {:drain, topic})
  end

  # -- server --

  @impl true
  def init(_opts) do
    {:ok, %{topics: %{}, redeliveries: %{}}}
  end

  @impl true
  def handle_call({:publish, topic, payload, publish_time}, _from, st) do
    t = topic_state(st, topic)
    id = t.seq + 1

    envelope = %{
      id: id,
      data: payload |> Jason.encode!() |> Base.encode64(),
      publishTime: publish_time
    }

    for pid <- t.subscribers, is_pid(pid) do
      GenServer.cast(pid, {:pubsub_message, topic, envelope})
    end

    t = %{t | seq: id, messages: t.messages ++ [envelope]}
    st = %{st | topics: Map.put(st.topics, topic, t)}

    {:reply, {:ok, id}, st}
  end

  def handle_call({:subscribe, topic, pid}, _from, st) do
    t = topic_state(st, topic)
    t = %{t | subscribers: Enum.uniq(t.subscribers ++ [pid])}
    st = %{st | topics: Map.put(st.topics, topic, t)}
    {:reply, :ok, st}
  end

  def handle_call({:redeliver, topic, pid}, _from, st) do
    t = topic_state(st, topic)

    st =
      Enum.reduce(t.messages, st, fn envelope, st_acc ->
        GenServer.cast(pid, {:pubsub_message, topic, envelope})
        bump_redelivery(st_acc, pid, envelope.id)
      end)

    {:reply, {:ok, length(t.messages)}, st}
  end

  def handle_call({:drain, topic}, _from, st) do
    {:reply, {:ok, Map.get(st.topics, topic, %{messages: []}).messages}, st}
  end

  def handle_call(:redeliveries, _from, st) do
    {:reply, {:ok, st.redeliveries}, st}
  end

  defp topic_state(st, topic) do
    Map.get(st.topics, topic, %{seq: 0, subscribers: [], messages: []})
  end

  defp bump_redelivery(st, pid, id) do
    key = {pid, id}
    %{st | redeliveries: Map.update(st.redeliveries, key, 1, &(&1 + 1))}
  end
end
