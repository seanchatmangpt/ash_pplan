defmodule AshPPlan.Reactor.Durable.HealthGateWiringTest do
  @moduledoc """
  Court for the opt-in JPL three-phase lifecycle wired into `Checkpointed.run/3`.

  Phases: (1) `pre_check` BEFORE the intent record (`Run.record/4`) and before the inner run —
  refusal is fail-closed (`{:error, {:health_gate_violation, reason}}`) with zero state mutation
  (no checkpoint, no inner effect); (2) actuate = the inner run, ending in `Run.record/4`; (3)
  `post_telemetry` AFTER `Run.record/4` success, telemetry-only (failures logged, not raised).
  The cached-output replay short-circuit skips all three phases (replay invariance).
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Checkpointed, Engine}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Reactor.Durable.Testing
  alias AshPPlan.Test.Effects

  @fx Module.concat(__MODULE__, Fx)
  @log Module.concat(__MODULE__, Log)

  defmodule Gate do
    @moduledoc "Health gate counting into the lane effects agent and the ordered phase log."
    def pre_check(_arguments, _context) do
      AshPPlan.Reactor.Durable.HealthGateWiringTest.append(:pre_check)
      Effects.run(AshPPlan.Reactor.Durable.HealthGateWiringTest.Fx, :pre_check)
    end

    def post_telemetry(_value, _arguments, _context) do
      AshPPlan.Reactor.Durable.HealthGateWiringTest.append(:post_telemetry)
      Effects.run(AshPPlan.Reactor.Durable.HealthGateWiringTest.Fx, :post_telemetry)
    end
  end

  defmodule RefusingGate do
    @moduledoc "Health gate whose pre-check refuses with a typed reason."
    def pre_check(_arguments, _context) do
      AshPPlan.Reactor.Durable.HealthGateWiringTest.append(:pre_check)
      Effects.run(AshPPlan.Reactor.Durable.HealthGateWiringTest.Fx, :pre_check)
      {:error, :safety_margin_violated}
    end

    def post_telemetry(_v, _a, _c), do: :ok
  end

  defmodule Inner do
    @moduledoc "Inner step: actuation is one counted inner effect."
    use Reactor.Step

    @impl true
    def run(_arguments, _context, options) do
      AshPPlan.Reactor.Durable.HealthGateWiringTest.append(:inner_run)
      Effects.run(AshPPlan.Reactor.Durable.HealthGateWiringTest.Fx, :inner_run)
      {:ok, Keyword.get(options, :output, :payload)}
    end
  end

  defmodule UngatedInner do
    @moduledoc "Inner step for the ungated regression court."
    use Reactor.Step

    @impl true
    def run(_arguments, _context, _options) do
      AshPPlan.Reactor.Durable.HealthGateWiringTest.append(:inner_run)
      {:ok, :ungated_payload}
    end
  end

  defmodule SilentGate do
    @moduledoc "Gate module exporting neither pre_check/2 nor post_telemetry/3."
  end

  @run_id "hg-wiring"

  def append(event), do: Agent.update(@log, &(&1 ++ [event]))

  def events, do: Agent.get(@log, & &1)

  defp fx_counts do
    %{
      pre_check: Effects.count(@fx, :pre_check),
      inner_run: Effects.count(@fx, :inner_run),
      post_telemetry: Effects.count(@fx, :post_telemetry)
    }
  end

  setup_all do
    # Unlinked on purpose: the setup_all process exits before tests run, and a
    # linked agent would die with it. Stopped in on_exit.
    {:ok, _} = Agent.start(fn -> %{counts: %{}, fail_after: %{}} end, name: @fx)
    {:ok, _} = Agent.start(fn -> [] end, name: @log)

    on_exit(fn ->
      Agent.stop(@fx)
      Agent.stop(@log)
    end)

    :ok
  end

  setup do
    Agent.update(@fx, &%{&1 | counts: %{}, fail_after: %{}})
    Agent.update(@log, fn _ -> [] end)
    {:ok, store} = Ets.start_link()
    {:ok, _run} = Engine.start(store, %{id: @run_id})
    Process.put(:hg_store, store)
    :ok
  end

  defp store, do: Process.get(:hg_store)

  defp context(checkpoints \\ %{}) do
    %{
      current_step: struct!(Reactor.Step, name: "gated_step", impl: Inner, arguments: []),
      durable: %{
        store: store(),
        store_module: Ets,
        run_id: @run_id,
        checkpoints: checkpoints
      }
    }
  end

  defp durable_opts,
    do: [durable_name: "gated_step", durable_inner: Inner, health_gate: Gate]

  defp refusing_opts,
    do: [durable_name: "gated_step", durable_inner: Inner, health_gate: RefusingGate]

  defp replay_context do
    cps =
      store()
      |> Ets.checkpoints(@run_id)
      |> Map.new(fn {step_key, cp} -> {step_key, cp.output} end)

    context(cps)
  end

  test "gated step admits: phases execute in order pre_check -> inner_run -> post_telemetry" do
    {:ok, out} = Checkpointed.run(%{}, context(), durable_opts())

    assert out == :payload
    assert events() == [:pre_check, :inner_run, :post_telemetry]
    assert fx_counts() == %{pre_check: 1, inner_run: 1, post_telemetry: 1}
    assert Testing.recorded(store(), @run_id, "gated_step") == :payload
  end

  test "refusal is fail-closed: typed error, zero effects, zero checkpoints" do
    result = Checkpointed.run(%{}, context(), refusing_opts())

    assert result == {:error, {:health_gate_violation, :safety_margin_violated}}
    assert events() == [:pre_check]
    assert fx_counts() == %{pre_check: 1, inner_run: 0, post_telemetry: 0}
    assert map_size(Ets.checkpoints(store(), @run_id)) == 0
  end

  test "replay bypasses all three phases (replay invariance)" do
    # Attempt 1: live execution — full lifecycle, checkpoint recorded.
    {:ok, out1} = Checkpointed.run(%{}, context(), durable_opts())
    assert events() == [:pre_check, :inner_run, :post_telemetry]
    before = fx_counts()

    # Attempt 2 (post-kill semantics: the attempt died after `record`): the store-loaded
    # checkpoint short-circuits BEFORE pre_check — no phase touches any effect.
    {:ok, out2} = Checkpointed.run(%{}, replay_context(), durable_opts())

    assert out2 == out1
    assert fx_counts() == before
    assert events() == [:pre_check, :inner_run, :post_telemetry]
  end

  test "ungated step regression: no health_gate opt -> inner runs, zero gate effects" do
    {:ok, out} =
      Checkpointed.run(%{}, context(), durable_name: "gated_step", durable_inner: UngatedInner)

    assert out == :ungated_payload
    assert events() == [:inner_run]
    assert fx_counts() == %{pre_check: 0, inner_run: 0, post_telemetry: 0}
    assert Testing.recorded(store(), @run_id, "gated_step") == :ungated_payload
  end

  test "gate module without pre_check/2 or post_telemetry/3 passes through cleanly" do
    {:ok, out} =
      Checkpointed.run(%{}, context(),
        durable_name: "gated_step",
        durable_inner: UngatedInner,
        health_gate: SilentGate
      )

    assert out == :ungated_payload
    assert events() == [:inner_run]
    assert Testing.recorded(store(), @run_id, "gated_step") == :ungated_payload
  end
end
