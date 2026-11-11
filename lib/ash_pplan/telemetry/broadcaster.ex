defmodule AshPPlan.Telemetry.Broadcaster do
  @moduledoc """
  Local PubSub telemetry broadcaster — OTP stdlib only (a registry GenServer
  with per-subscriber monitors; no Phoenix.PubSub, no registry dep).

  ## API

    * `subscribe/2` — subscribe the calling process to a topic.
    * `unsubscribe/2` — remove the caller's subscription.
    * `broadcast/3` — fire-and-forget publish of an event to all topic
      subscribers; each subscriber receives `{:ash_pplan_telemetry, event}`.
    * `dropped_count/1` — cumulative slow/dead-subscriber drops for a topic.

  ## Event envelope

  `broadcast/3` wraps a typed `AshPPlan.Telemetry.Event.t()` struct in:

      %{topic:, type:, run_id:, seq:, data:, emitted_at:}

  where `seq` is a per-topic monotonic counter starting at 1 (single writer =
  the GenServer, so ordering is total per topic).

  ## Backpressure / lifecycle law

  * **Fire-and-forget**: delivery is `send/2`; `broadcast/3` never blocks on a
    subscriber and never raises on subscriber failure.
  * **Dead subscriber**: each subscriber is monitored; a `:DOWN` removes it.
    As a second net, the broadcast loop also checks liveness and prunes.
  * **Slow-subscriber policy: drop-with-counter (chosen and stated)**. Before
    sending, the broadcaster reads `process_info(pid, :message_queue_len)`;
    a subscriber whose queue exceeds `@max_queue_len` (default 256) is
    unsubscribed and the drop counted — no infinite mailbox growth, no
    selective receive in the broadcaster (that would serialise the slow
    consumer against the broadcaster itself). Subscribers that need every
    event must drain faster than producers emit or observe
    `dropped_count/1` / the `:subscriber_dropped` signal.

  The broadcaster runs under the application supervision tree when
  `AshPPlan.Telemetry` is started; tests use `start_supervised/1`.
  """

  use GenServer

  alias AshPPlan.Telemetry.Event

  @max_queue_len 256
  @signal :ash_pplan_telemetry

  defstruct topics: %{}

  # ── client API ──────────────────────────────────────────────────────────

  @doc "Starts the broadcaster. `name:` registers the process (default named)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @doc """
  Subscribes the calling process to `topic`. Idempotent for an already
  subscribed pid. Returns `:ok`.
  """
  @spec subscribe(GenServer.server(), term()) :: :ok
  def subscribe(server \\ __MODULE__, topic) do
    GenServer.call(server, {:subscribe, topic, self()})
  end

  @doc "Removes the calling process's subscription to `topic`. Returns `:ok`."
  @spec unsubscribe(GenServer.server(), term()) :: :ok
  def unsubscribe(server \\ __MODULE__, topic) do
    GenServer.call(server, {:unsubscribe, topic, self()})
  end

  @doc """
  Publishes `data` (a typed `AshPPlan.Telemetry.Event.t()` struct) to all
  subscribers of `topic`. Fire-and-forget: returns `:ok` regardless of
  subscriber state. Stamps the envelope with the topic's next monotonic seq.
  """
  @spec broadcast(GenServer.server(), term(), Event.t()) :: :ok
  def broadcast(server \\ __MODULE__, topic, %struct_module{} = data) do
    _ = struct_module
    GenServer.call(server, {:broadcast, topic, data})
  end

  @doc "Cumulative count of dropped (dead or slow) subscribers for `topic`."
  @spec dropped_count(GenServer.server(), term()) :: non_neg_integer()
  def dropped_count(server \\ __MODULE__, topic) do
    GenServer.call(server, {:dropped_count, topic})
  end

  # ── server ──────────────────────────────────────────────────────────────

  @impl GenServer
  def init(:ok), do: {:ok, %__MODULE__{}}

  @impl GenServer
  def handle_call({:subscribe, topic, pid}, _from, state) do
    topic_state = topic_state(state, topic)

    cond do
      Map.has_key?(topic_state.subscribers, pid) ->
        {:reply, :ok, put_topic(state, topic, topic_state)}

      true ->
        ref = Process.monitor(pid)
        subscribers = Map.put(topic_state.subscribers, pid, ref)
        {:reply, :ok, put_topic(state, topic, %{topic_state | subscribers: subscribers})}
    end
  end

  def handle_call({:unsubscribe, topic, pid}, _from, state) do
    case Map.fetch(state.topics, topic) do
      {:ok, topic_state} ->
        case Map.pop(topic_state.subscribers, pid) do
          {nil, _subscribers} ->
            {:reply, :ok, state}

          {ref, subscribers} ->
            Process.demonitor(ref, [:flush])
            topic_state = %{topic_state | subscribers: subscribers}
            {:reply, :ok, put_topic(state, topic, topic_state)}
        end

      :error ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:broadcast, topic, data}, _from, state) do
    topic_state = topic_state(state, topic)
    seq = topic_state.seq + 1

    event = Event.to_event(data, topic, seq)

    subscribers =
      Enum.reduce(topic_state.subscribers, topic_state.subscribers, fn {pid, ref}, acc ->
        if alive_and_draining?(pid) do
          send(pid, {@signal, event})
          acc
        else
          Process.demonitor(ref, [:flush])
          Map.delete(acc, pid)
        end
      end)

    dropped =
      topic_state.dropped + (map_size(topic_state.subscribers) - map_size(subscribers))

    topic_state = %{seq: seq, subscribers: subscribers, dropped: dropped}
    {:reply, :ok, put_topic(state, topic, topic_state)}
  end

  def handle_call({:dropped_count, topic}, _from, state) do
    {:reply, topic_state(state, topic).dropped, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    topics =
      Map.new(state.topics, fn {topic, topic_state} ->
        case Map.pop(topic_state.subscribers, pid) do
          {^ref, subscribers} ->
            {topic, %{topic_state | subscribers: subscribers, dropped: topic_state.dropped + 1}}

          _other ->
            {topic, topic_state}
        end
      end)

    {:noreply, %{state | topics: topics}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── helpers ─────────────────────────────────────────────────────────────

  defp topic_state(state, topic) do
    Map.get(state.topics, topic, %{seq: 0, subscribers: %{}, dropped: 0})
  end

  defp put_topic(state, topic, topic_state) do
    %{state | topics: Map.put(state.topics, topic, topic_state)}
  end

  # A subscriber is dropped (not merely skipped) when its process is dead or
  # its mailbox exceeds @max_queue_len — drop-with-counter backpressure law.
  # Process.info/2 rejects :alive as an item key (invalid item), so liveness is
  # carried by the nil return: dead pid -> nil. Single-key Process.info/2
  # returns a tuple on Elixir 1.19 (a keyword list on older versions).
  defp alive_and_draining?(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} -> len <= @max_queue_len
      [message_queue_len: len] -> len <= @max_queue_len
      nil -> false
    end
  end
end
