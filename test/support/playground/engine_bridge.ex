defmodule AshPPlan.Playground.EngineBridge do
  @moduledoc """
  Translates Tactical COP LiveView/CAD events into addressed operations on the
  `AshPPlan.Reactor.Durable` engine and store.

  All mutations respect the formal boundary:
  - Resumptions are point-to-point addressed by `run_id` + `waiter_label`.
  - Financial adjustments (`bump_nte/5`) enforce the 22% gross margin invariant,
    failing closed with structured refusals when breached.
  - Checkpoint tapes are read directly from the persistent store.
  """

  alias AshPPlan.Reactor.Durable.{Engine, Store}

  @doc """
  Initiates a scenario run in the durable store.
  """
  @spec start_scenario(GenServer.server(), atom(), String.t()) ::
          {:ok, AshPPlan.Reactor.Durable.Record.t()} | {:error, term()}
  def start_scenario(store, scenario_type \\ :nominal, run_id \\ "rel-1") do
    now = DateTime.utc_now()

    attrs = %{
      id: run_id,
      status: :waiting,
      scenario: scenario_type,
      started_at: now
    }

    case Store.Ets.start_run(store, attrs) do
      {:ok, record} ->
        # Pre-seed initial committed checkpoint
        _ =
          Store.Ets.record(
            store,
            run_id,
            "step-1-intake",
            "intake_validated",
            %{status: :admitted, timestamp: now},
            %{actor: "DispatcherAgent", seq: 1}
          )

        # Park on the approval gate
        _ =
          Store.Ets.park(
            store,
            run_id,
            "gate_approved",
            :signal,
            DateTime.add(now, 3600, :second)
          )

        {:ok, record}

      {:error, :exists} ->
        {:ok, Store.Ets.get_run(store, run_id)}
    end
  end

  @doc """
  Delivers an addressed resumption signal to a paused gate.
  """
  @spec resume_gate(GenServer.server(), String.t(), atom() | String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def resume_gate(store, run_id, label, payload) do
    label_str = to_string(label)

    with {:ok, _signal} <- Store.Ets.deliver_signal(store, run_id, label_str, payload) do
      # Attempt to drive the run forward
      case Engine.attempt(store, run_id) do
        {:completed, res} -> {:ok, %{status: :completed, result: res}}
        {:parked, next_gate} -> {:ok, %{status: :parked, gate: next_gate}}
        {:refused, reason} -> {:error, {:refusal, reason}}
        :ended -> {:ok, %{status: :ended}}
        :taken -> {:ok, %{status: :claimed_by_other}}
        other -> {:ok, %{status: :advanced, outcome: other}}
      end
    end
  end

  @doc """
  Adjusts the Not-To-Exceed (NTE) financial ceiling while enforcing the gross margin floor.
  Fails closed if `margin < floor_pct`.
  """
  @spec bump_nte(GenServer.server(), String.t(), number(), number(), float()) ::
          {:ok, map()} | {:error, {:refusal, :margin_invariant_breach, map()}}
  def bump_nte(store, run_id, nte_amount, quote_amount, floor_pct \\ 22.0) do
    nte = nte_amount * 1.0
    quote_val = quote_amount * 1.0

    margin_pct =
      if nte > 0 do
        (nte - quote_val) / nte * 100.0
      else
        0.0
      end

    if margin_pct >= floor_pct do
      payload = %{
        nte: nte,
        quote: quote_val,
        margin: Float.round(margin_pct, 2),
        approved: true
      }

      # Record checkpoint confirming the financial envelope admission
      _ =
        Store.Ets.record(
          store,
          run_id,
          "step-nte-adjustment",
          "financial_envelope_admitted",
          payload,
          %{seq: System.unique_integer([:positive])}
        )

      resume_gate(store, run_id, :gate_approved, payload)
    else
      {:error,
       {:refusal, :margin_invariant_breach,
        %{
          computed_margin: Float.round(margin_pct, 2),
          required_floor: floor_pct,
          nte: nte,
          quote: quote_val
        }}}
    end
  end

  @doc """
  Synthesizes a FOND contingency detour to route around an abandoned or declined task.
  """
  @spec synthesize_detour(GenServer.server(), String.t(), map()) :: {:ok, map()}
  def synthesize_detour(store, run_id, params \\ %{}) do
    now = DateTime.utc_now()
    detour_payload = Map.merge(%{tier: 2, action: :detour_activated, timestamp: now}, params)

    _ =
      Store.Ets.record(
        store,
        run_id,
        "step-detour-synthesis",
        "contingency_detour_admitted",
        detour_payload,
        %{seq: System.unique_integer([:positive])}
      )

    resume_gate(store, run_id, :gate_approved, %{detour: detour_payload})
  end

  @doc """
  Reads standing checkpoints for a run from the store.
  """
  @spec get_run_tape(GenServer.server(), String.t()) :: [map()]
  def get_run_tape(store, run_id) do
    case Store.Ets.checkpoints(store, run_id) do
      checkpoints when is_map(checkpoints) ->
        checkpoints
        |> Map.values()
        |> Enum.sort_by(& &1.seq)
        |> Enum.map(fn cp ->
          %{
            id: cp.step_key,
            label: cp.label,
            output: cp.output,
            seq: cp.seq
          }
        end)

      _ ->
        []
    end
  end
end
