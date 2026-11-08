defmodule AshPPlan.Reactor.Durable.ReplayFence.FenceKill do
  @moduledoc """
  Kill-plan Agent in the `phase_kill_test.exs` CrashStore idiom: the plan is
  data in a named Agent; the victim is killed with an untrappable
  `Process.exit(pid, :kill)`.

  A boundary is armed per test with a firing budget (`nth`), so a store-level
  point can be placed at the 1st or 2nd occurrence of the boundary.
  """
  @plan __MODULE__.Plan

  def start_plan, do: Agent.start_link(fn -> %{} end, name: @plan)
  def fired?, do: Agent.get(@plan, &Map.get(&1, :fired, false))
  def disarm, do: Agent.update(@plan, fn _ -> %{} end)

  @doc "Arm one kill: `point` fires (killing `victim`) on its `nth` occurrence."
  def arm(point, nth, victim),
    do: Agent.update(@plan, fn _ -> %{point: point, left: nth, victim: victim, fired: false} end)

  @doc """
  Called from store callbacks and from inside the counting step at the armed
  boundary. Untrappable kill of the caller's own process.
  """
  @spec maybe_kill(atom()) :: :ok
  def maybe_kill(point) do
    hit =
      Agent.get_and_update(@plan, fn
        %{point: ^point, left: 1, victim: v} = p -> {v, %{p | point: nil, fired: true}}
        %{point: ^point, left: n} = p -> {nil, %{p | left: n - 1}}
        p -> {nil, p}
      end)

    if hit do
      Process.exit(hit, :kill)

      # If the caller is a step task rather than the victim itself, stop it
      # here so no boundary-firing task outruns the killed attempt.
      if hit != self(), do: Process.sleep(:infinity)
    end

    :ok
  end
end

defmodule AshPPlan.Reactor.Durable.ReplayFence.FenceStore do
  @moduledoc """
  A real `AshPPlan.Reactor.Durable.Store` (hand-written, not a mock): every
  callback delegates to the ETS store; the armed boundaries fire inside
  `claim/5` and `record/6`. All state lives in the real ETS store.
  """
  @behaviour AshPPlan.Reactor.Durable.Store

  alias AshPPlan.Reactor.Durable.ReplayFence.FenceKill
  alias AshPPlan.Reactor.Durable.Store.Ets

  @impl true
  def start_run(s, a), do: Ets.start_run(s, a)

  @impl true
  def get_run(s, id), do: Ets.get_run(s, id)

  @impl true
  def list_runs(s), do: Ets.list_runs(s)

  @impl true
  def transition(s, id, from, to, attrs), do: Ets.transition(s, id, from, to, attrs)

  @impl true
  def claim(s, id, claimer, lease, now) do
    result = Ets.claim(s, id, claimer, lease, now)
    with {:ok, _} <- result, do: FenceKill.maybe_kill(:after_claim)
    result
  end

  @impl true
  def release_claim(s, id, claimer), do: Ets.release_claim(s, id, claimer)

  @impl true
  def checkpoints(s, id), do: Ets.checkpoints(s, id)

  @impl true
  def standing(s, id), do: Ets.standing(s, id)

  @impl true
  def record(s, id, key, label, output, meta) do
    result = Ets.record(s, id, key, label, output, meta)

    # `$intent` rows are intent metadata, not the effect's checkpoint: the
    # :after_record kill boundary fires only on OUTPUT records, so an intent
    # record can never satisfy the "record survived" premise.
    unless AshPPlan.Reactor.Durable.Key.intent_row?(%{label: label}),
      do: FenceKill.maybe_kill(:after_record)

    result
  end

  @impl true
  def claim_undo(s, id, key, now), do: Ets.claim_undo(s, id, key, now)

  @impl true
  def mark_undone(s, id, key, now), do: Ets.mark_undone(s, id, key, now)

  @impl true
  def release_undo(s, id, key), do: Ets.release_undo(s, id, key)

  @impl true
  def deliver_signal(s, id, name, payload), do: Ets.deliver_signal(s, id, name, payload)

  @impl true
  def pending_signal(s, id, name), do: Ets.pending_signal(s, id, name)

  @impl true
  def consume_signal(s, sid, now), do: Ets.consume_signal(s, sid, now)

  @impl true
  def park(s, id, name, kind, deadline, opts), do: Ets.park(s, id, name, kind, deadline, opts)

  @impl true
  def get_waiter(s, id, name), do: Ets.get_waiter(s, id, name)

  @impl true
  def waiters(s, id), do: Ets.waiters(s, id)

  @impl true
  def release(s, id, name), do: Ets.release(s, id, name)

  @impl true
  def release_all(s, id), do: Ets.release_all(s, id)

  @impl true
  def signals(s, id), do: Ets.signals(s, id)
end

defmodule AshPPlan.Reactor.Durable.ReplayFence.FenceEffect do
  @moduledoc """
  Effect-counting step with optional step-local kill boundaries around the
  inner effect: `:pre_effect` kills before the effect runs; `:post_effect`
  kills after the effect ran but before `Run.record` can write a checkpoint.
  With `use_token: true` the step models an externally idempotent effect: it
  dedupes on `context.durable_intent_token` through `TokenCache` (the stand-in
  for the external system), returning the first result without re-counting on a
  token hit. Without it the step is token-ignoring (at-least-once).
  """
  use Reactor.Step

  alias AshPPlan.Reactor.Durable.ReplayFence.{FenceKill, TokenCache}
  alias AshPPlan.Test.Effects

  @impl true
  def run(_arguments, context, options) do
    effects = Keyword.fetch!(options, :effects)
    effect = Keyword.fetch!(options, :effect)
    point = Keyword.get(options, :kill_point)
    use_token = Keyword.get(options, :use_token, false)

    if point == :pre_effect, do: FenceKill.maybe_kill(:pre_effect)

    result =
      if use_token do
        # Token-using step: the token IS the external idempotency key; a repeat
        # with the same token is deduped by the external system (TokenCache).
        token = context[:durable_intent_token]

        case TokenCache.get(token) do
          {:dup, first} ->
            {:ok, first}

          :miss ->
            case Effects.run(effects, effect) do
              {:ok, n} ->
                first = {effect, n}
                TokenCache.put(token, first)
                {:ok, first}

              err ->
                err
            end
        end
      else
        case Effects.run(effects, effect) do
          {:ok, n} -> {:ok, {effect, n}}
          {:error, _} = err -> err
        end
      end

    if point == :post_effect, do: FenceKill.maybe_kill(:post_effect)

    result
  end
end

defmodule AshPPlan.Reactor.Durable.ReplayFence.TokenCache do
  @moduledoc """
  Stand-in for the external system's idempotency dedupe: maps
  `durable_intent_token` -> first effect result. A repeat under the same
  token returns the recorded result WITHOUT re-counting the effect.
  """
  @name __MODULE__

  def start_link, do: Agent.start_link(fn -> %{} end, name: @name)
  def put(token, value), do: Agent.update(@name, &Map.put(&1, token, value))

  def get(token) do
    Agent.get(@name, fn
      %{^token => first} -> {:dup, first}
      %{} -> :miss
    end)
  end

  def tokens, do: Agent.get(@name, & &1)
  def reset, do: Agent.update(@name, fn _ -> %{} end)
end

defmodule AshPPlan.Reactor.Durable.ReplayFence.FenceAdapter do
  @moduledoc "Test adapter mapping the fence-chain capabilities to `FenceEffect`."
  @behaviour AshPPlan.Reactor.Adapter

  alias AshPPlan.Reactor.Durable.ReplayFence.FenceEffect

  @impl true
  def id, do: :fence_fx

  @impl true
  def available?, do: true

  @impl true
  def ops, do: [:fx_a_op, :fx_b_op, :fx_c_op]

  @impl true
  def step(op, options) do
    table = %{
      fx_a_op: {FenceEffect, [effect: :fx_a]},
      fx_b_op: {FenceEffect, [effect: :fx_b]},
      fx_c_op: {FenceEffect, [effect: :fx_c]}
    }

    AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
  end
end

defmodule AshPPlan.Reactor.Durable.ReplayFence.GuardProbe do
  @moduledoc """
  Guard-state Agent for the neutralised-guard court: the guard fun consults
  it, the test flips the answer between attempts, and `calls` counts every
  consultation of the ORIGINAL guard fun (zero on a replayed step means the
  checkpoint, not the guard, supplied the answer).
  """
  @name __MODULE__

  def start_link, do: Agent.start_link(fn -> %{answer: :cont, calls: 0} end, name: @name)

  def set_answer(answer), do: Agent.update(@name, &%{&1 | answer: answer})
  def answer, do: Agent.get(@name, & &1.answer)

  def count_call, do: Agent.update(@name, &%{&1 | calls: &1.calls + 1})
  def calls, do: Agent.get(@name, & &1.calls)

  @doc "The real guard fun injected into the guarded step."
  def fun(_arguments, _context) do
    count_call()

    case answer() do
      :cont -> :cont
      :skip -> {:halt, :skipped}
    end
  end
end

defmodule AshPPlan.Reactor.Durable.ReplayFenceTest do
  @moduledoc """
  Replay-fence court: the Temporal-style guarantees of the durable engine
  under untrappable crash, over a real ETS store, driven by injected clock
  and bounded polls only (`Testing.drain`, no `Process.sleep`).

  Part 1 - cache short-circuit: a 3-effect workflow replays with ZERO inner
  effect impl invocations; every step is served from its checkpoint.

  Part 2 - kill at each of 5 boundaries around the effect/record sequence,
  recovery by lease lapse + fresh attempt. Records the per-point behavior
  table: which points dedupe (total effects = 3) and which duplicate (the
  at-least-once window: effect ran, checkpoint lost). On the current
  on-disk state the intent-token boundary IS the checkpoint record - there
  is no separate intent row - so `:post_effect` (after the effect,
  pre-record) is the one duplicating point FOR TOKEN-IGNORING steps (each
  row's effects are counted by the token-ignoring FenceEffect path). The
  intent-token describe below closes that point FOR TOKEN-USING steps: the
  standing `$intent` row is adopted on replay, the same
  `durable_intent_token` returns, and the external system (TokenCache) dedupes.

  Part 3 - guard re-evaluation: a replayed step preserves the FIRST guard
  answer (`Run.decorate/2` neutralises guards for recorded steps); the
  flipped guard is proven live by a fresh run where it really skips.

  Anti-vacuity: every kill scenario asserts the plan fired and the attempt
  died (`:killed`); a fresh run of the same plan repeats the effects, so
  the dedupe assertions can fail.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{
    Clock,
    Engine,
    Key,
    ReplayFence.FenceAdapter,
    ReplayFence.FenceKill,
    ReplayFence.GuardProbe,
    ReplayFence.TokenCache,
    Testing
  }

  alias AshPPlan.Reactor.Durable.ReplayFence.FenceStore
  alias AshPPlan.Reactor.Durable.Run
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Effects

  @lease_lapse_ms 3_600_000

  setup do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :fence_fx, FenceAdapter)
    )

    Clock.use_test_clock()

    on_exit(fn ->
      Application.put_env(:ash_pplan, :extra_adapters, previous)
      Clock.reset()
    end)

    {:ok, store} = Ets.start_link()
    {:ok, _} = Effects.start_link()
    {:ok, _} = FenceKill.start_plan()
    {:ok, _} = GuardProbe.start_link()
    {:ok, _} = TokenCache.start_link()
    {:ok, store: store}
  end

  # -- model / bindings ------------------------------------------------------

  defp model do
    tasks = [
      %{
        id: :fx_a,
        capability: "domain.alpha",
        depends_on: [],
        outcomes: [:success],
        terminal_outcomes: [:success]
      },
      %{
        id: :fx_b,
        capability: "domain.beta",
        depends_on: [:fx_a],
        outcomes: [:success],
        terminal_outcomes: [:success]
      },
      %{
        id: :fx_c,
        capability: "domain.gamma",
        depends_on: [:fx_b],
        outcomes: [:success],
        terminal_outcomes: [:success]
      }
    ]

    AshPPlan.Workflow.Model.new(
      name: "replay_fence_chain",
      goal: "fx_done",
      tasks: tasks,
      methods: [%{id: :chain, task: "fx_done", subtasks: [:fx_a, :fx_b, :fx_c]}]
    )
    |> case do
      {:ok, m} -> m
      {:error, e} -> raise "court model invalid: #{inspect(e)}"
    end
  end

  defp bindings(kill_point, use_token \\ false) do
    ops = [
      fx_a: {:fx_a_op, "domain.alpha"},
      fx_b: {:fx_b_op, "domain.beta"},
      fx_c: {:fx_c_op, "domain.gamma"}
    ]

    Map.new(ops, fn {task, {op, cap}} ->
      {task,
       %AshPPlan.Realization{
         capability: cap,
         provider: :fence_fx,
         binding: %{adapter: :fence_fx, op: op},
         options:
           [effects: AshPPlan.Test.Effects, effect: task, kill_point: kill_point] ++
             if(use_token, do: [use_token: true], else: [])
       }}
    end)
  end

  defp attrs(id, kill_point, use_token \\ false) do
    %{
      id: id,
      model: model(),
      bindings: bindings(kill_point, use_token),
      inputs: %{input: %{}},
      context: %{},
      parent: nil
    }
  end

  # -- attempt helpers -------------------------------------------------------

  defp attempt_killed(store, run_id, arm_fn) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {:victim, self()})
        arm_fn.(self())
        Engine.attempt(store, run_id, store_module: FenceStore)
        send(parent, :attempt_survived)
      end)

    assert_receive {:victim, ^pid}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 15_000
    reason
  end

  defp converge(store, _run_id) do
    FenceKill.disarm()
    Clock.advance(@lease_lapse_ms)
    Testing.drain(store, store_module: FenceStore)
  end

  defp assert_completed(store, run_id) do
    assert Testing.status(store, run_id) == :completed,
           "run #{run_id}: #{inspect(Engine.fetch(store, run_id))}"
  end

  # Standing labels are `inspect`ed URIs (`...#step-fx_a`); reduce to the step
  # suffix so the court asserts on the chain shape, not label formatting.
  defp tape_labels(store, run_id) do
    store
    |> Engine.steps(run_id)
    |> Enum.map(
      &(&1.label
        |> to_string
        |> String.replace("\"", "")
        |> String.split("#step-")
        |> List.last()
        |> String.to_atom())
    )
  end

  defp total_effects, do: Effects.all() |> Map.values() |> Enum.sum()

  # -- Part 1: cache short-circuit -------------------------------------------

  test "cache short-circuit: 3 effects run once; replay serves every step from checkpoints",
       %{store: store} do
    {:ok, _} = Engine.start(store, attrs("fence-cache", nil))
    Testing.drain(store, store_module: FenceStore)
    assert_completed(store, "fence-cache")
    assert Effects.all() == %{fx_a: 1, fx_b: 1, fx_c: 1}

    # A fresh attempt at a completed run is terminal-absorbing: nothing re-runs.
    assert Engine.attempt(store, "fence-cache", store_module: FenceStore) == :ended
    assert Effects.all() == %{fx_a: 1, fx_b: 1, fx_c: 1}

    # Replay through a real crash + recovery: kill after fx_a's record.
    {:ok, _} = Engine.start(store, attrs("fence-cache-crash", nil))
    reason = attempt_killed(store, "fence-cache-crash", &FenceKill.arm(:after_record, 1, &1))
    assert reason == :killed
    assert FenceKill.fired?()

    converge(store, "fence-cache-crash")
    assert_completed(store, "fence-cache-crash")

    # Across BOTH attempts the crash run added EXACTLY one execution per
    # effect: every step after the crash was checkpoint-served (zero inner
    # effect impl invocations on replay). Counters are test-scoped, so the
    # assertion is a delta against the completed `fence-cache` run above.
    assert Effects.all() == %{fx_a: 2, fx_b: 2, fx_c: 2}
    assert total_effects() == 6

    # The standing values ARE the recorded outputs (this run's own count per
    # effect), not re-derived values.
    tape = Engine.steps(store, "fence-cache-crash")
    assert Enum.map(tape, &elem(&1.output, 1)) == [2, 2, 2]
  end

  # -- Part 2: kill-point behavior table --------------------------------------

  # {point, arm point, nth, effects after the killed attempt, effects after recovery, verdict}
  @table [
    {:before_intent, :after_claim, 1, %{}, %{fx_a: 1, fx_b: 1, fx_c: 1}, :dedupe},
    {:after_intent_pre_effect, :pre_effect, 1, %{}, %{fx_a: 1, fx_b: 1, fx_c: 1}, :dedupe},
    {:after_effect_pre_record, :post_effect, 1, %{fx_a: 1}, %{fx_a: 2, fx_b: 1, fx_c: 1},
     :duplicate},
    {:after_record, :after_record, 1, %{fx_a: 1}, %{fx_a: 1, fx_b: 1, fx_c: 1}, :dedupe},
    {:between_steps, :after_record, 2, %{fx_a: 1, fx_b: 1}, %{fx_a: 1, fx_b: 1, fx_c: 1}, :dedupe}
  ]

  describe "kill-point behavior table" do
    for {point, arm_point, nth, first, final, verdict} <- @table do
      test "kill #{point}: #{verdict}", %{store: store} do
        point = unquote(point)
        arm_point = unquote(arm_point)
        first = unquote(Macro.escape(first))
        final = unquote(Macro.escape(final))
        id = "fence-#{point}"

        step_kill = unquote(if arm_point in [:pre_effect, :post_effect], do: arm_point)
        {:ok, _} = Engine.start(store, attrs(id, step_kill))

        reason = attempt_killed(store, id, &FenceKill.arm(arm_point, unquote(nth), &1))
        assert reason == :killed, "kill at #{point}: DOWN reason #{inspect(reason)}"
        assert FenceKill.fired?()
        assert Effects.all() == first, "first-segment effects differ at #{point}"

        converge(store, id)
        assert_completed(store, id)
        assert Effects.all() == final, "per-point table broken at #{point}"

        assert tape_labels(store, id) == [:fx_a, :fx_b, :fx_c],
               "standing tape repeats a step at #{point}"

        if unquote(verdict) == :duplicate do
          assert total_effects() == 4, "expected the at-least-once duplicate at #{point}"
        else
          assert total_effects() == 3, "unexpected duplicate at #{point}"
        end
      end
    end
  end

  describe "intent-token dedupe at the after-effect-pre-record kill point" do
    test "token-using step dedupes (P3 boundary closed for token users)", %{store: store} do
      id = "fence-token-aep"
      {:ok, _} = Engine.start(store, attrs(id, :post_effect, true))
      reason = attempt_killed(store, id, &FenceKill.arm(:post_effect, 1, &1))
      assert reason == :killed
      assert FenceKill.fired?()
      assert Effects.all() == %{fx_a: 1}

      converge(store, id)
      assert_completed(store, id)

      # Dedupe: fx_a never re-ran its effect; fx_b/fx_c ran once each.
      assert Effects.all() == %{fx_a: 1, fx_b: 1, fx_c: 1}
      assert total_effects() == 3

      # Token stability: one distinct token PER STEP (fx_a, fx_b, fx_c each use
      # the token), and fx_a's token served both of its attempts unchanged —
      # it IS the deterministic intent id of fx_a's step name.
      assert map_size(TokenCache.tokens()) == 3
      fx_a_row = Enum.find(Engine.steps(store, id), &(&1.label =~ "step-fx_a"))
      assert fx_a_row.name != nil
      fx_a_token = Key.intent_id(id, fx_a_row.name)
      assert Map.has_key?(TokenCache.tokens(), fx_a_token)

      # `$intent` rows stand in the store but never appear as steps/tape rows.
      refute Enum.any?(Engine.steps(store, id), &String.contains?(&1.label, "$intent"))
      refute Enum.any?(Testing.tape(store, id), &String.contains?(&1, "$intent"))

      assert Enum.count(FenceStore.checkpoints(store, id), fn {_k, cp} ->
               Key.intent_row?(cp)
             end) == 3

      assert tape_labels(store, id) == [:fx_a, :fx_b, :fx_c]
    end

    test "token-ignoring step duplicates (the boundary claim is honest)",
         %{store: store} do
      # Same kill point, no `use_token`: the at-least-once window stays open.
      id = "fence-notoken-aep"
      {:ok, _} = Engine.start(store, attrs(id, :post_effect, false))
      reason = attempt_killed(store, id, &FenceKill.arm(:post_effect, 1, &1))
      assert reason == :killed
      assert FenceKill.fired?()
      assert Effects.all() == %{fx_a: 1}

      converge(store, id)
      assert_completed(store, id)
      assert Effects.all() == %{fx_a: 2, fx_b: 1, fx_c: 1}
      assert total_effects() == 4
      assert map_size(TokenCache.tokens()) == 0
    end
  end

  test "anti-vacuity: an unarmed plan does not kill and the run completes", %{store: store} do
    FenceKill.disarm()
    {:ok, _} = Engine.start(store, attrs("fence-unarmed", nil))
    Testing.drain(store, store_module: FenceStore)
    assert_completed(store, "fence-unarmed")
    refute FenceKill.fired?()
    assert total_effects() == 3
  end

  test "anti-vacuity: a fresh run of the same plan repeats the effects", %{store: store} do
    {:ok, _} = Engine.start(store, attrs("fence-av-a", nil))
    Testing.drain(store, store_module: FenceStore)
    assert total_effects() == 3

    {:ok, _} = Engine.start(store, attrs("fence-av-b", nil))
    Testing.drain(store, store_module: FenceStore)
    assert total_effects() == 6
  end

  # -- Part 3: guard re-evaluation --------------------------------------------

  test "replayed step preserves the FIRST guard answer; flipped guard proven live on a fresh run",
       %{store: store} do
    {:ok, _} = Engine.start(store, attrs("fence-guard", nil))
    GuardProbe.set_answer(:cont)

    # Attempt 1 (court-local driver, disclosed): real store, real Checkpointed
    # wrapper, guard injected post-reactor_for (the model projection attaches
    # no guards, so this is the only seam a guard can enter through).
    {:ok, _} = run_decorated(store, "fence-guard")
    assert Effects.all() == %{fx_a: 1, fx_b: 1, fx_c: 1}
    assert GuardProbe.calls() == 1
    assert tape_labels(store, "fence-guard") == [:fx_a, :fx_b, :fx_c]

    # Attempt 2: the guard flips, but every step is recorded - the neutralised
    # guard must hold the FIRST answer (:cont) without consulting the flipped
    # fun, and the cache must serve all three steps.
    GuardProbe.set_answer(:skip)
    {:ok, _} = run_decorated(store, "fence-guard")
    assert Effects.all() == %{fx_a: 1, fx_b: 1, fx_c: 1}, "replay re-ran an effect"
    assert GuardProbe.calls() == 1, "the flipped guard was consulted on replay"
    assert tape_labels(store, "fence-guard") == [:fx_a, :fx_b, :fx_c]
    assert total_effects() == 3

    # Non-vacuity: the SAME flipped guard, applied through `Run.decorate_step`
    # to a fresh (checkpoint-less) context, really skips fx_a - so the
    # replayed :cont above is the neutralisation's work, not an inert guard.
    # (Full-reactor proof is blocked upstream: reactor 1.0.7 has no executor
    # clause for a guard-skip outcome `:skipped` in EITHER runner - both crash
    # with FunctionClauseError when a guarded step with dependents is skipped.
    # That is recorded as a court finding, not worked around here.)
    {:ok, reactor} = Run.reactor_for(Engine.fetch(store, "fence-guard"))
    fx_a = Enum.find(reactor.steps, &name_is_fx_a?(&1))
    assert fx_a != nil

    guarded = %{
      fx_a
      | guards: [%Reactor.Guard{description: "fence-guard", fun: &GuardProbe.fun/2} | fx_a.guards]
    }

    decorated = Run.decorate_step(guarded, %{durable: %{checkpoints: %{}}})

    # The neutralised guard is a rewritten `fun` on the step struct. On a
    # fresh context the original fun IS consulted and its :skip holds.
    [guard] = decorated.guards
    assert guard.fun.([], %{durable: %{checkpoints: %{}}}) == {:halt, :skipped}
    assert GuardProbe.calls() == 2, "the neutralised guard bypassed the flipped fun"

    # With the checkpoint present, the rewritten fun holds :cont without
    # consulting the flipped fun (this is the attempt-2 behavior, shown here
    # in isolation).
    {:ok, recorded} =
      FenceStore.checkpoints(store, "fence-guard")
      |> Enum.find(fn {_k, cp} -> cp.label =~ "step-fx_a" end)
      |> case do
        {_k, cp} -> {:ok, cp.output}
        nil -> flunk("no fx_a checkpoint")
      end

    key = AshPPlan.Reactor.Durable.Key.for_name(fx_a.name)
    assert guard.fun.([], %{durable: %{checkpoints: %{key => recorded}}}) == :cont
    assert GuardProbe.calls() == 2, "the flipped guard was consulted despite a checkpoint"
  end

  defp name_is_fx_a?(%{name: name}), do: name_is_fx_a?(name)
  defp name_is_fx_a?(name), do: String.ends_with?(to_string(name), "step-fx_a")

  # Court-local driver: identical to `Run.run/3` except that one step's guards
  # are injected after `reactor_for/1`. Everything under it (Check-pointed
  # wrapper, checkpoint load, ETS store, effects) is the real machinery.
  defp run_decorated(store, run_id) do
    record = Engine.fetch(store, run_id)
    assert record != nil
    {:ok, reactor} = Run.reactor_for(record)
    assert Enum.find(reactor.steps, &name_is_fx_a?(&1)), "no fx_a step"

    steps =
      Enum.map(reactor.steps, fn
        s ->
          if name_is_fx_a?(s) do
            guard = %Reactor.Guard{description: "fence-guard", fun: &GuardProbe.fun/2}
            %{s | guards: [guard | s.guards]}
          else
            s
          end
      end)

    cps =
      store
      |> FenceStore.checkpoints(run_id)
      |> Enum.reject(fn {_k, cp} -> cp.undone_at != nil end)
      |> Map.new(fn {k, cp} -> {k, cp.output} end)

    durable = %{store: store, store_module: FenceStore, run_id: run_id, checkpoints: cps}

    # Sync execution: reactor 1.0.7's async runner cannot normalise a
    # guard-skip result; the sync runner handles it, and `Checkpointed`
    # semantics are identical either way.
    steps = Enum.map(steps, &%{&1 | async?: false})
    reactor = Run.decorate(%{reactor | steps: steps}, durable)

    Reactor.run(reactor, record.inputs, record.context || %{},
      max_concurrency: 1,
      halt_timeout: 5_000
    )
  end
end
