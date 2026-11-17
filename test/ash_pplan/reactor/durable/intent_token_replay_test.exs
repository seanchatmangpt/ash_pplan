defmodule AshPPlan.Reactor.Durable.IntentTokenReplayTest do
  @moduledoc """
  L03 court (ARD Tier 2 §4 pre-effect intent token; Tier 3 §2 dedup) over the REAL
  `Engine` + `Store.Wal` (tmp file) + a real Agent-backed broker.

  Law under test: the wrapper checkpoints a `$intent` row whose output IS the
  deterministic intent token BEFORE the inner step body runs, and a replayed
  attempt of the same (run, step) receives the byte-identical token, so an
  effect keyed on the token lands exactly once at the external system even when
  the first attempt dies after the effect and before its output checkpoint.

  Why the first attempt dies by an untrappable kill rather than a `raise`: in
  this engine a step `raise` is routed by `Middleware.event({:run_error, _})` to
  `Run.record_error/2` -> `:unwinding` -> `:failed`, and `:failed` is absorbing
  (`Status` `failed: []`), so `Engine.attempt/3` answers `:ended` and never
  replays a raised step. The crash that DOES produce an `Engine.attempt` replay
  is the attempt process dying mid-step with the claim still on the record; the
  lease is lapsed by `Clock.advance/1` (no sleep) and a fresh attempt replays
  through the standing WAL. The WAL is closed and re-opened between the two
  attempts, so attempt 2 replays from the durable log, not from the first
  attempt's in-memory index.

  Chicago: no mocks. The broker is a hand-written Agent (a real degraded
  external system), the store is the real WAL on a tmp path, counters are Agent
  state, never the process dictionary.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Realization
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Key}
  alias AshPPlan.Reactor.Durable.Store.Wal
  alias AshPPlan.Workflow.Model

  @adapter_id :l03_intent_fx
  @lease_lapse_ms Engine.lease_ms() + 1

  defmodule Broker do
    @moduledoc """
    Real degraded external broker: effects are stored keyed by the intent token
    (publish-with-idempotency-key semantics). Also the court's observation
    ledger: every body invocation appends the token it saw and whether the
    `$intent` row was already standing in the store at effect time.
    """
    use Agent

    def start_link(name),
      do:
        Agent.start_link(
          fn ->
            %{
              attempts: 0,
              token_attempts: %{},
              tokens: [],
              effects: %{},
              intent_row_at_effect: [],
              victim: nil,
              trace: []
            }
          end,
          name: name
        )

    @doc "The attempt process registers itself as the kill victim before `Engine.attempt`."
    def arm_victim(name, pid), do: Agent.update(name, &%{&1 | victim: pid})
    def victim(name), do: Agent.get(name, & &1.victim)

    @doc "Step-side progress trace (diagnostic: names how far the body got on a failed run)."
    def trace(name, event), do: Agent.update(name, &%{&1 | trace: &1.trace ++ [event]})

    @doc """
    Publish `payload` under `token`. Returns `{attempt_no_for_this_token, :published | :deduped}`.
    `intent_standing?` is the step's real read of the store at effect time.
    """
    def publish(name, token, payload, intent_standing?) when is_binary(token) do
      Agent.get_and_update(name, fn s ->
        n = Map.get(s.token_attempts, token, 0) + 1

        {verdict, effects} =
          case s.effects do
            %{^token => _} -> {:deduped, s.effects}
            effects -> {:published, Map.put(effects, token, payload)}
          end

        s = %{
          s
          | attempts: s.attempts + 1,
            token_attempts: Map.put(s.token_attempts, token, n),
            tokens: s.tokens ++ [token],
            effects: effects,
            intent_row_at_effect: s.intent_row_at_effect ++ [intent_standing?]
        }

        {{n, verdict}, s}
      end)
    end

    def state(name), do: Agent.get(name, & &1)
  end

  defmodule Publish do
    @moduledoc """
    The effect step. On the first invocation for a token it publishes to the
    broker and then kills the ATTEMPT process (the pid the attempt registered in
    the broker before `Engine.attempt`), after the broker effect and before
    `Checkpointed` can record the output - the exact at-least-once window the
    intent token is meant to close. Reactor may run the body in an
    `async_nolink` Task rather than the attempt process, so the kill names the
    victim explicitly (the `replay_fence_test.exs` idiom) and the body then
    waits on a monitor for the victim's DOWN - a real observable, never a sleep -
    so no body outlives the attempt and records an output into the store.
    """
    use Reactor.Step

    @impl true
    def async?(_step), do: false

    @impl true
    def run(_arguments, context, options) do
      broker = Keyword.fetch!(options, :broker)
      Broker.trace(broker, :entered)
      token = Map.fetch!(context, :durable_intent_token)
      Broker.trace(broker, {:token, token})
      %{store: store, store_module: mod, run_id: run_id} = context.durable

      # Real store read at effect time: is the `$intent` row (step_key == token)
      # already durable before this body does anything external?
      intent_standing? =
        store
        |> mod.checkpoints(run_id)
        |> Map.has_key?(token)

      Broker.trace(broker, {:intent_standing_at_effect, intent_standing?})

      case Broker.publish(broker, token, %{run: run_id, step: :publish}, intent_standing?) do
        {1, :published} ->
          # First attempt OF THIS TOKEN: effect landed, output never recorded.
          victim = Broker.victim(broker) || self()
          Broker.trace(broker, {:killing, victim, self()})
          ref = Process.monitor(victim)
          Process.exit(victim, :kill)

          # If we ARE the victim the line above never returns. Otherwise hold
          # this body until the attempt is observed dead, then end it too.
          receive do
            {:DOWN, ^ref, :process, ^victim, _} -> exit(:killed)
          end

        {_n, verdict} ->
          Broker.trace(broker, {:returning, verdict})
          {:ok, {verdict, token}}
      end
    end
  end

  defmodule Confirm do
    @moduledoc "Second step: records only the token it was handed (a different step name)."
    use Reactor.Step

    @impl true
    def async?(_step), do: false

    @impl true
    def run(_arguments, context, _options),
      do: {:ok, {:confirm, Map.fetch!(context, :durable_intent_token)}}
  end

  defmodule Adapter do
    @moduledoc false
    @behaviour AshPPlan.Reactor.Adapter

    @impl true
    def id, do: :l03_intent_fx

    @impl true
    def available?, do: true

    @impl true
    # Capability ids must use a shipped `AshPPlan.Capability` family
    # (`lib/ash_pplan/capability.ex:9-11`); `event` is one, `Broker` is not.
    def ops, do: [:event_publish, :event_confirm]

    @impl true
    def step(op, options) do
      table = %{
        event_publish: {AshPPlan.Reactor.Durable.IntentTokenReplayTest.Publish, []},
        event_confirm: {AshPPlan.Reactor.Durable.IntentTokenReplayTest.Confirm, []}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  # -- fixtures ---------------------------------------------------------------

  defp install_adapter! do
    previous = Application.fetch_env(:ash_pplan, :extra_adapters)

    current =
      case previous do
        {:ok, v} -> Map.new(v)
        :error -> %{}
      end

    Application.put_env(:ash_pplan, :extra_adapters, Map.put(current, @adapter_id, Adapter))

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:ash_pplan, :extra_adapters, v)
        :error -> Application.delete_env(:ash_pplan, :extra_adapters)
      end
    end)

    :ok
  end

  defp attrs(id, broker) do
    {:ok, model} =
      Model.new(
        name: :l03_intent_token_replay,
        goal: :published,
        tasks: [
          [id: :publish, capability: "Event.Publish", depends_on: []],
          [id: :confirm, capability: "Event.Confirm", depends_on: [:publish]]
        ]
      )

    bindings =
      Map.new(model.tasks, fn t ->
        {t.id,
         %Realization{
           capability: t.capability,
           provider: @adapter_id,
           binding: %{adapter: @adapter_id, op: Realization.op_for(t.capability)},
           options: [broker: broker]
         }}
      end)

    %{id: id, model: model, bindings: bindings, inputs: %{input: %{}}, context: %{}}
  end

  defp open_wal!(path) do
    {:ok, wal} = Wal.open(path)
    on_exit(fn -> Wal.close(wal) end)
    wal
  end

  # Attempt in a monitored process that registers itself as the kill victim first;
  # the DOWN reason is the court's crash witness. A survived attempt reports its
  # outcome so a wrong exit reason is diagnosable from the assertion message.
  defp attempt_in_process(wal, run_id, broker) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Broker.arm_victim(broker, self())
        outcome = Engine.attempt(wal, run_id, store_module: Wal)
        send(parent, {:attempt_survived, self(), outcome})
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 15_000

    survived =
      receive do
        {:attempt_survived, ^pid, outcome} -> outcome
      after
        0 -> :none
      end

    {reason, survived}
  end

  defp assert_killed!(wal, run_id, broker) do
    {reason, survived} = attempt_in_process(wal, run_id, broker)

    assert reason == :killed,
           "attempt exited #{inspect(reason)} (survived outcome: #{inspect(survived)}); " <>
             "run: #{inspect(Engine.fetch(wal, run_id, store_module: Wal))}; " <>
             "broker trace: #{inspect(Broker.state(broker).trace)}"

    :ok
  end

  defp step_suffix(label) do
    label |> to_string() |> String.replace("\"", "") |> String.split("#step-") |> List.last()
  end

  setup do
    install_adapter!()
    Clock.use_test_clock(~U[2026-01-01 00:00:00Z])
    on_exit(&Clock.reset/0)

    broker = :"l03_broker_#{System.unique_integer([:positive])}"
    {:ok, _} = Broker.start_link(broker)

    path =
      Path.join(System.tmp_dir!(), "l03_intent_#{System.unique_integer([:positive])}.wal")

    on_exit(fn -> File.rm(path) end)

    %{broker: broker, path: path}
  end

  @tag :serial
  test "intent token: checkpointed before the effect, byte-identical on the replayed attempt, broker holds one effect",
       %{broker: broker, path: path} do
    id = "l03-#{System.unique_integer([:positive])}"
    wal = open_wal!(path)
    {:ok, _} = Engine.start(wal, attrs(id, broker), store_module: Wal)

    # -- attempt 1: effect lands, attempt dies before the output record ----------
    assert_killed!(wal, id, broker)

    s1 = Broker.state(broker)
    assert s1.attempts == 1
    assert map_size(s1.effects) == 1
    assert s1.intent_row_at_effect == [true], "intent row was not standing at effect time"
    [token1] = s1.tokens

    # Store after the crash: the `$intent` row for publish stands, NO output row.
    standing1 = Wal.standing(wal, id)
    assert [intent1] = Enum.filter(standing1, &Key.intent_row?/1)
    assert step_suffix(intent1.label) == "publish"
    assert intent1.output == token1
    assert intent1.step_key == token1
    assert Enum.reject(standing1, &Key.intent_row?/1) == []

    run1 = Engine.fetch(wal, id, store_module: Wal)
    assert run1.status == :pending
    assert run1.claimed_by != nil, "the dead attempt must still hold the claim"

    # -- restart: close and re-open the WAL (replay from the durable log) ----------
    :ok = Wal.close(wal)
    wal2 = open_wal!(path)
    reopened = Engine.fetch(wal2, id, store_module: Wal)
    assert reopened.status == :pending
    assert [_] = Enum.filter(Wal.standing(wal2, id), &Key.intent_row?/1)

    # Lease lapses by arithmetic, not by sleeping.
    Clock.advance(@lease_lapse_ms)

    # -- attempt 2: replay --------------------------------------------------------
    assert {:completed, _} = Engine.attempt(wal2, id, store_module: Wal)

    s2 = Broker.state(broker)
    assert s2.attempts == 2, "the publish body must have run twice"
    assert s2.tokens == [token1, token1], "replayed token differs"
    assert [t_a, t_b] = s2.tokens
    assert t_a === t_b and byte_size(t_a) == byte_size(t_b)
    assert map_size(s2.effects) == 1, "broker holds more than one effect"
    assert s2.intent_row_at_effect == [true, true]

    # -- store record order: intent row BEFORE the effect's output row ------------
    standing2 = Wal.standing(wal2, id)
    publish_rows = Enum.filter(standing2, &(step_suffix(&1.label) == "publish"))
    intent_row = Enum.find(publish_rows, &Key.intent_row?/1)
    output_row = Enum.find(publish_rows, &(not Key.intent_row?(&1)))
    assert intent_row != nil and output_row != nil
    assert intent_row.seq < output_row.seq, "output checkpoint precedes its intent row"
    assert output_row.output == {:deduped, token1}
    # the intent row seq is the earliest publish-step write; nothing of publish precedes it
    assert intent_row.seq == publish_rows |> Enum.map(& &1.seq) |> Enum.min()

    # Token equals the pure function of (run id, real step name).
    assert token1 == Key.intent_id(id, output_row.name)

    # `$intent` rows are metadata: filtered from the step tape.
    assert Enum.map(Engine.steps(wal2, id, store_module: Wal), &step_suffix(&1.label)) ==
             ["publish", "confirm"]

    # -- non-vacuity: equality is load-bearing ------------------------------------
    confirm_row =
      Enum.find(standing2, &(step_suffix(&1.label) == "confirm" and not Key.intent_row?(&1)))

    assert {:confirm, confirm_token} = confirm_row.output
    assert confirm_token != token1, "a different step name must derive a different token"
    assert confirm_token == Key.intent_id(id, confirm_row.name)
    assert Key.intent_id(id <> "-other", output_row.name) != token1
    assert Key.intent_id(id, :not_a_real_step) != token1

    # Two body invocations, one effect: the dedup is the token's work, not the engine's.
    assert s2.attempts == 2 and map_size(s2.effects) == 1
  end

  @tag :serial
  test "non-vacuity: a different run id under the same model mints a different token and a second broker effect",
       %{broker: broker, path: path} do
    wal = open_wal!(path)
    id_a = "l03-a-#{System.unique_integer([:positive])}"
    id_b = id_a <> "-b"

    for id <- [id_a, id_b] do
      {:ok, _} = Engine.start(wal, attrs(id, broker), store_module: Wal)
      assert_killed!(wal, id, broker)
      Clock.advance(@lease_lapse_ms)
      assert {:completed, _} = Engine.attempt(wal, id, store_module: Wal)
    end

    s = Broker.state(broker)
    assert s.attempts == 4
    assert map_size(s.effects) == 2
    [ta, ta2, tb, tb2] = s.tokens
    assert ta == ta2 and tb == tb2
    assert ta != tb
    assert Map.keys(s.effects) |> Enum.sort() == Enum.sort([ta, tb])
  end
end
