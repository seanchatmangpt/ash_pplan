defmodule AshPPlan.Telemetry.EmissionPointsTest do
  @moduledoc """
  Lane Z4 emission-points court: a REAL durable workflow (the canonical
  QualifiedFulfillment spine) runs with the BufferingEmitter configured as the
  emit impl; the court asserts on final buffered state, not call counts.

  * `run_status_changed` sequence == the Status transitions actually observed
    on the store record (re-read from the store, not asserted a priori).
  * `checkpoint_committed` count == standing checkpoints re-read from the store.
  * `invariant_refused` fires on a real health-gate refusal via HealthGate.execute
    and via Checkpointed's pre_check wiring.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.Engine
  alias AshPPlan.Reactor.Durable.HealthGate
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Telemetry.Emit.BufferingEmitter
  alias AshPPlan.Reactor.Durable.Clock
  alias AshPPlan.Test.{CanonicalExample, DurableFx, Effects}

  setup do
    DurableFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    start_supervised!(BufferingEmitter)
    {:ok, effects} = Effects.start_link()

    on_exit(fn ->
      if Process.alive?(effects), do: GenServer.stop(effects)
    end)

    Application.put_env(:ash_pplan, :emit_impl, AshPPlan.Telemetry.Emit.BufferingEmitter)
    {:ok, store} = Ets.start_link()
    prev = Application.get_env(:ash_pplan, :emit_impl)
    Application.put_env(:ash_pplan, :emit_impl, AshPPlan.Telemetry.Emit.BufferingEmitter)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:ash_pplan, :emit_impl)
        impl -> Application.put_env(:ash_pplan, :emit_impl, impl)
      end
    end)

    %{store: store}
  end

  test "run_status_changed sequence matches observed Status transitions; checkpoint count matches",
       %{store: store} do
    %{id: id, store: store, store_mod: store_mod} = CanonicalExample.run(store)

    # The record's final status is the LAST element of every observed transition.
    final = Engine.fetch(store, id, store_module: store_mod)

    drained = BufferingEmitter.drain()

    status_events =
      drained
      |> Enum.filter(&(&1.type == :run_status_changed and &1.run_id == id))
      |> Enum.map(&{&1.data.from, &1.data.to})

    assert status_events != []
    assert Enum.all?(status_events, fn {from, _to} -> not is_nil(from) end)

    # Every emission is a lawful transition: its :to is the NEXT emission's :from
    # (and the last :to is the final observed record status).
    {chain_ok, _} =
      status_events
      |> Enum.reverse()
      |> Enum.reduce({true, final.status}, fn {from, to}, {ok, next} ->
        {ok and to == next and not is_nil(from), from}
      end)

    assert chain_ok, "emitted chain #{inspect(status_events)} vs final #{final.status}"

    checkpoints = Engine.steps(store, id, store_module: store_mod)

    checkpoint_events =
      Enum.filter(drained, &(&1.type == :checkpoint_committed and &1.run_id == id))

    assert length(checkpoint_events) == length(checkpoints),
           "checkpoint_committed #{length(checkpoint_events)} vs standing #{length(checkpoints)}"

    assert Enum.all?(
             checkpoint_events,
             &is_struct(&1.data, AshPPlan.Telemetry.Event.CheckpointCommitted)
           )
  end

  test "invariant_refused fires on a real health-gate refusal (HealthGate.execute)" do
    {:error, {:refused, {:health_gate_violation, :nope}}} =
      HealthGate.execute(
        %{impl: Z4RefusingGate},
        %{},
        %{durable: %{run_id: :z4_refused_run}},
        fn _args, _ctx -> flunk("run_fun must never run on a refused pre_check") end
      )

    assert [%{type: :invariant_refused, run_id: :z4_refused_run, data: data}] =
             refused_events(:z4_refused_run)

    assert data.invariant == {:health_gate, :pre_check}
  end

  test "invariant_refused fires on a real health-gate refusal (Checkpointed wiring)" do
    step = %{
      impl: {AshPPlan.Reactor.Step.Return, [value: :x]},
      name: :z4_gate_step,
      arguments: %{}
    }

    ctx = %{
      current_step: step,
      durable: %{store: self(), store_module: Ets, run_id: :z4_cp_refused}
    }

    options = [
      durable_name: :z4_gate,
      durable_inner: {AshPPlan.Reactor.Step.Return, [value: :x]},
      health_gate: Z4RefusingGate
    ]

    assert {:error, {:health_gate_violation, :nope}} =
             AshPPlan.Reactor.Durable.Checkpointed.run(%{value: :x}, ctx, options)

    assert [
             %{
               type: :invariant_refused,
               run_id: :z4_cp_refused,
               data: %{invariant: {:health_gate, :pre_check}}
             }
           ] =
             refused_events(:z4_cp_refused)
  end

  defp refused_events(run_id) do
    BufferingEmitter.drain()
    |> Enum.filter(&(&1.type == :invariant_refused and &1.run_id == run_id))
  end
end

defmodule Z4RefusingGate do
  @moduledoc false
  def pre_check(_arguments, _context), do: {:error, :nope}
end
