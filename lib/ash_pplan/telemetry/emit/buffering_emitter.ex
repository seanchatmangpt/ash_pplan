defmodule AshPPlan.Telemetry.Emit.BufferingEmitter do
  @moduledoc """
  Test/dev `AshPPlan.Telemetry.Emit` implementation — a bounded in-memory ring
  that collects emitted events as real envelopes, so courts assert on final
  buffered state instead of call counts (a real collaborator, not a mock).

  ## Behaviour

  * `emit/2` (the behaviour callback) stamps the envelope with the monotonic
    `seq` exactly like `AshPPlan.Telemetry.Broadcaster` and appends it to the
    ring. The GenServer is the single writer, so emission order == seq order
    even under concurrent emitters — no lost seq. `seq` survives `drain/1`
    (drain empties the ring, never rewinds the counter).
  * Bounded: when the ring exceeds `:max` events (default 1024) the OLDEST is
    evicted and the `:evicted` counter advances.
  * `drain/1` returns every buffered envelope in emission (== seq) order and
    resets the buffer and its counters.
  * `counts/1` returns `%{buffered:, evicted:, by_type:}` over the CURRENT
    buffer (cumulative evictions included).

  ## Envelope shape

  Same as the broadcaster: `%{topic:, type:, run_id:, seq:, data:, emitted_at:}`
  with `type` resolved via `AshPPlan.Telemetry.Emit.Event.type_of/1` (covers
  both vocabularies).

  See Also: `AshPPlan.Telemetry.Emit`, `AshPPlan.Telemetry.Emit.Noop`
  """

  use GenServer
  @behaviour AshPPlan.Telemetry.Emit

  alias AshPPlan.Telemetry.Emit.Event

  @default_max 1024

  defstruct buffer: :queue.new(), max: @default_max, seq: 0, buffered: 0, evicted: 0, by_type: %{}

  # ── client API ──────────────────────────────────────────────────────────

  @doc """
  Starts the emitter. Options: `:name` (default `__MODULE__`), `:max` ring
  bound (default 1024).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.take(opts, [:max]), name: name)
  end

  @doc """
  Behaviour callback: buffer `event` under `opts[:topic]`. Returns `:ok`
  unconditionally (emission is advisory — never a failure path).
  """
  @impl AshPPlan.Telemetry.Emit
  def emit(event, opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:emit, event, Keyword.fetch!(opts, :topic)})
  end

  @doc """
  Drains the ring: returns all buffered envelopes in emission (== seq) order
  and resets buffer + counters (the seq counter itself never rewinds).
  """
  @spec drain(GenServer.server()) :: [map()]
  def drain(server \\ __MODULE__) do
    GenServer.call(server, :drain)
  end

  @doc "Counts over the CURRENT buffer: `%{buffered:, evicted:, by_type:}`."
  @spec counts(GenServer.server()) :: %{
          buffered: non_neg_integer(),
          evicted: non_neg_integer(),
          by_type: %{AshPPlan.Telemetry.Emit.Event.type() => non_neg_integer()}
        }
  def counts(server \\ __MODULE__) do
    GenServer.call(server, :counts)
  end

  # ── server ──────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    {:ok, %__MODULE__{max: Keyword.get(opts, :max, @default_max)}}
  end

  @impl GenServer
  def handle_call({:emit, event, topic}, _from, state) do
    seq = state.seq + 1

    envelope = %{
      topic: topic,
      type: Event.type_of(event),
      run_id: Event.run_id_of(event),
      seq: seq,
      data: event,
      emitted_at: DateTime.utc_now()
    }

    buffer = :queue.in(envelope, state.buffer)

    {buffer, buffered, evicted, by_type} =
      evict_to_bound(buffer, state.buffered + 1, state.evicted, state.max, state.by_type)

    by_type = Map.update(by_type, envelope.type, 1, &(&1 + 1))

    {:reply, :ok,
     %{
       state
       | buffer: buffer,
         seq: seq,
         buffered: buffered,
         evicted: evicted,
         by_type: by_type
     }}
  end

  def handle_call(:drain, _from, state) do
    # :queue.to_list is already oldest-first (rear-append); no reverse.
    {:reply, :queue.to_list(state.buffer), %__MODULE__{max: state.max, seq: state.seq}}
  end

  def handle_call(:counts, _from, state) do
    {:reply, %{buffered: state.buffered, evicted: state.evicted, by_type: state.by_type}, state}
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp evict_to_bound(buffer, buffered, evicted, max, by_type) when buffered > max do
    {{_, %{type: type}}, buffer} = :queue.out(buffer)
    # evicted events leave the buffer, so by_type tracks the CURRENT buffer
    by_type =
      case Map.fetch(by_type, type) do
        {:ok, 1} -> Map.delete(by_type, type)
        {:ok, n} -> Map.put(by_type, type, n - 1)
        :error -> by_type
      end

    evict_to_bound(buffer, buffered - 1, evicted + 1, max, by_type)
  end

  defp evict_to_bound(buffer, buffered, evicted, _max, by_type),
    do: {buffer, buffered, evicted, by_type}
end
