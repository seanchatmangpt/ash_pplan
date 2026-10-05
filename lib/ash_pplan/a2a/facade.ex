defmodule AshPPlan.A2A.Facade do
  @moduledoc """
  The A2A-provider facade over the durable engine: the surface a remote-agent
  consumer binds, exposed natively by ash_pplan so no consumer re-derives it.

  The in-tree consumer is `AshA2A.Providers.PPlan`
  (`~/ash_a2a/lib/ash_a2a/providers/pplan.ex`), which binds exactly these
  ash_pplan primitives — `AshPPlan.Reactor.Durable.Engine`
  (`start/attempt/signal/fetch/cancel`), `AshPPlan.Reactor.Durable.Run.store_module/1`,
  the nine-status `AshPPlan.Reactor.Durable.Status` machine, and the store's
  `waiters/2` — and maps this repo's run lifecycle onto A2A task states:

  | ash_pplan run status | A2A task state |
  |----------------------|----------------|
  | `:pending`           | `:submitted`   |
  | `:waiting`           | `:input_required` |
  | `:polling`           | `:working`     |
  | `:unwinding` / `:cancelling` / `unwind_blocked` | `:working` |
  | `:completed`         | `:completed`   |
  | `:failed`            | `:failed`      |
  | `:cancelled`         | `:canceled`    |

  This facade owns that mapping on the ash_pplan side of the seam: every entry
  point returns `{:ok, a2a_state, detail}` (or a typed `{:error, reason}`) with
  `a2a_state` one of `:submitted`, `:working`, `:input_required`, `:completed`,
  `:failed`, `:canceled`, so a consumer needs nothing but this module. Like the
  consumer, it is start-or-adopt (the engine's `start/3` is idempotent by run
  id: a re-dispatch adopts the run unchanged, never a duplicate execution),
  signal-based resume (a follow-up payload lands as a consume-once signal on
  the run's parked waiter and one attempt follows), and read-only status /
  claim-CAS cancel.

  ## Gaps (named honestly, nothing faked)

    * ash_pplan has no first-class input-required status — and none is added
      here (Status is generated from the ontology; the facade maps instead).
      `:input_required` is the parked status `:waiting`: a signal waiter. A
      plan without an Await step can never park that way; such a run completes
      or fails in one hop. [UNSUPPORTED-capability:
      ash_pplan input-required-as-first-class-status]
    * Run inputs are bound at start only: adopting an existing run returns it
      unchanged, so a follow-up payload reaches the plan ONLY as a `resume/4`
      signal — never by re-dispatch with new inputs.
    * A2A `:auth_required` / `:rejected` have no counterpart here and are
      never produced. Rollback states surface as `:working`; read `status/3`'s
      detail map for the underlying run status.

  ## Falsifier

  This facade is falsified if any of these hold on a real store
  (courts: `test/a2a_facade_test.exs`):

    1. `start_or_adopt/5` twice with the same key grows the checkpoint tape or
       re-executes any step (double execution).
    2. `resume/4` on an `:input_required` run does not consume exactly one
       pending signal, or a second `resume/4` moves a terminal state.
    3. A run parked on a deadline (`:polling`) is reported `:input_required` —
       the facade would be lying about who must act next.
    4. `to_state/1` is not total over `Status.all/0`, or maps an unknown atom
       to a state instead of refusing typed.
  """

  alias AshPPlan.Reactor.Durable.{Engine, Run, Status}

  @type store :: term()
  @type key :: String.t()
  @type state :: :submitted | :working | :input_required | :completed | :failed | :canceled

  @typedoc "See the individual entry points for the options each consumes."
  @type opt ::
          {:store_module, module()}
          | {:inputs, map()}
          | {:context, map()}
          | {:plan_iri, term()}
          | {:intent, term()}
          | {:signal, String.t()}
          | {:claimer, String.t()}
          | {:lease_ms, pos_integer()}

  @doc """
  Map an ash_pplan run status atom to an A2A task state (see the moduledoc table).

  Total over `Status.all/0`; anything outside the closed status set is a typed
  refusal, never a silent default.

  ## Examples

      iex> AshPPlan.A2A.Facade.to_state(:pending)
      {:ok, :submitted}

      iex> AshPPlan.A2A.Facade.to_state(:waiting)
      {:ok, :input_required}

      iex> AshPPlan.A2A.Facade.to_state(:polling)
      {:ok, :working}

      iex> AshPPlan.A2A.Facade.to_state(:unwind_blocked)
      {:ok, :working}

      iex> AshPPlan.A2A.Facade.to_state(:cancelled)
      {:ok, :canceled}

      iex> AshPPlan.A2A.Facade.to_state(:someday_status)
      {:error, {:unmapped_status, :someday_status}}

  """
  @spec to_state(atom()) :: {:ok, state()} | {:error, {:unmapped_status, atom()}}
  def to_state(:pending), do: {:ok, :submitted}
  def to_state(:waiting), do: {:ok, :input_required}
  def to_state(:polling), do: {:ok, :working}
  def to_state(:unwinding), do: {:ok, :working}
  def to_state(:cancelling), do: {:ok, :working}
  def to_state(:unwind_blocked), do: {:ok, :working}
  def to_state(:completed), do: {:ok, :completed}
  def to_state(:failed), do: {:ok, :failed}
  def to_state(:cancelled), do: {:ok, :canceled}
  def to_state(other), do: {:error, {:unmapped_status, other}}

  @doc """
  Whether `status` is in ash_pplan's closed run-status set (`Status.all/0`).

  ## Examples

      iex> AshPPlan.A2A.Facade.run_status?(:waiting)
      true

      iex> AshPPlan.A2A.Facade.run_status?(:someday_status)
      false

  """
  @spec run_status?(atom()) :: boolean()
  def run_status?(s), do: s in Status.all()

  @doc """
  Start (or adopt) a durable run keyed by the consumer's external key, and
  attempt it once.

  * `key` — the consumer's external task id; doubles as the durable run id.
    Idempotent: an existing run is adopted unchanged (the store returns
    `{:error, :exists}` and the engine hands back the existing record).
  * `model` — an `AshPPlan.Workflow.Model`; the caller's plan. This facade
    does not invent plans.
  * `bindings` — `%{task_id => AshPPlan.Realization{}}` realizing every model
    task; an unbound task is refused by the projector, not defaulted.
  * Options: `:inputs` (wrapped as `%{input: inputs}`), `:context`, `:plan_iri`,
    `:intent`, `:store_module`, `:claimer`, `:lease_ms`.

  Returns `{:ok, state, detail}`; `{:error, ...}` is provider-level failure only
  (a missing plan dependency, an engine policy refusal as `{:refused, reason}`).
  `detail` is the sealed result for `:completed`, the failure reason for
  `:failed`, the parked signal-waiter names for `:input_required`,
  `:claim_held` for `:working` when another attempt holds the claim, and nil
  for deadline-parked `:working`.
  """
  @spec start_or_adopt(store(), key(), AshPPlan.Workflow.Model.t(), map(), [opt()]) ::
          {:ok, state(), detail :: term()} | {:error, term()}
  def start_or_adopt(store, key, model, bindings, opts \\ [])
      when is_binary(key) and is_map(bindings) do
    attrs =
      %{
        id: key,
        model: model,
        bindings: bindings,
        inputs: wrap_inputs(Keyword.get(opts, :inputs, %{})),
        context: Keyword.get(opts, :context, %{})
      }
      |> maybe_put(:plan_iri, opts[:plan_iri])
      |> maybe_put(:intent, opts[:intent])

    {:ok, _record} = Engine.start(store, attrs, engine_opts(opts))
    attempt(store, key, opts)
  end

  @doc """
  One claimed attempt at the run, mapped to an A2A state.

  Outcomes mirror `Engine.attempt/3`: a completed attempt seals its result; a
  halt parks the run (`:waiting` -> `:input_required` with the waiter names as
  detail; `:polling` -> `:working`); a failure seals the reason; a rollback
  ending re-reads the record for its standing state; an engine policy refusal
  is typed; `:taken` means another attempt holds the claim (`:working` /
  `:claim_held`); a terminal run re-reads its sealed state; an unknown key is
  `{:error, :no_such_run}`.
  """
  @spec attempt(store(), key(), [opt()]) :: {:ok, state(), detail :: term()} | {:error, term()}
  def attempt(store, key, opts \\ []) do
    case Engine.attempt(store, key, engine_opts(opts)) do
      {:completed, result} -> {:ok, :completed, result}
      {:parked, :waiting} -> {:ok, :input_required, waiters(store, key, opts)}
      {:parked, :polling} -> {:ok, :working, nil}
      {:failed, reason} -> {:ok, :failed, reason}
      {:rolled_back, _ending} -> ended_state(store, key, opts)
      {:refused, reason} -> {:error, {:refused, reason}}
      :taken -> {:ok, :working, :claim_held}
      :ended -> ended_state(store, key, opts)
      :not_found -> {:error, :no_such_run}
    end
  end

  @doc """
  Deliver a follow-up message payload to a run and attempt it once.

  The payload becomes a consume-once signal. The signal name is the `:signal`
  opt or, unset, the name of the run's parked signal waiter — so the payload
  lands on the Await step that actually parked. An already-terminal run accepts
  no signal; its sealed state is returned unchanged. A run with no parked
  signal waiter refuses `{:error, :no_signal_waiter}`; more than one parked
  signal waiter refuses `{:error, {:ambiguous_waiters, names}}` — never a
  guessed broadcast.
  """
  @spec resume(store(), key(), term(), [opt()]) ::
          {:ok, state(), detail :: term()} | {:error, term()}
  def resume(store, key, payload, opts \\ []) when is_binary(key) do
    case Engine.fetch(store, key, engine_opts(opts)) do
      nil ->
        {:error, :no_such_run}

      %{status: status} = record ->
        if Status.terminal?(status) do
          {:ok, to_state!(status), record.result}
        else
          with {:ok, name} <- signal_name(store, key, opts),
               {:ok, _signal} <- Engine.signal(store, key, name, payload, engine_opts(opts)) do
            attempt(store, key, opts)
          end
        end
    end
  end

  @doc """
  Read-only current state of a run, without attempting it.

  Returns `{:ok, state, detail}` where `detail` carries the underlying run
  status, result, error, version, and parked signal-waiter names.
  """
  @spec status(store(), key(), [opt()]) :: {:ok, state(), detail :: term()} | {:error, term()}
  def status(store, key, opts \\ []) when is_binary(key) do
    case Engine.fetch(store, key, engine_opts(opts)) do
      nil ->
        {:error, :no_such_run}

      %{status: status} = record ->
        {:ok, to_state!(status),
         %{
           run_status: status,
           result: record.result,
           error: record.error,
           version: record.version,
           waiters: waiters(store, key, opts)
         }}
    end
  end

  @doc """
  Cancel a run (from `:pending` / `:waiting` / `:polling`), propagating to its
  non-terminal children.

  Returns `{:ok, :canceled, record}` on success; on `:not_cancellable` the run's
  current (terminal or rolling-back) state is returned instead of an error,
  since the caller's goal state is already standing. Losing the claim CAS to a
  live migration claim is `{:error, {:claim_held, key}}` — typed, not raised.
  """
  @spec cancel(store(), key(), [opt()]) :: {:ok, state(), detail :: term()} | {:error, term()}
  def cancel(store, key, opts \\ []) when is_binary(key) do
    case Engine.cancel(store, key, engine_opts(opts)) do
      {:ok, record} -> {:ok, :canceled, record}
      {:error, :not_cancellable} -> ended_state(store, key, opts)
      {:error, _} = error -> error
    end
  end

  @doc "Deliver a signal by explicit name, without attempting."
  @spec signal(store(), key(), String.t(), term(), [opt()]) ::
          {:ok, AshPPlan.Reactor.Durable.Signal.t()} | {:error, :no_such_run}
  def signal(store, key, name, payload, opts \\ []),
    do: Engine.signal(store, key, name, payload, engine_opts(opts))

  @doc "Fetch the run record (or `{:error, :no_such_run}` for an unknown key)."
  @spec fetch(store(), key(), [opt()]) ::
          {:ok, AshPPlan.Reactor.Durable.Record.t()} | {:error, :no_such_run}
  def fetch(store, key, opts \\ []) do
    case Engine.fetch(store, key, engine_opts(opts)) do
      nil -> {:error, :no_such_run}
      record -> {:ok, record}
    end
  end

  @doc """
  Names of the run's parked signal waiters, read from the real store.
  `:unknown` when the store module predates `waiters/2` — reported, not faked.
  """
  @spec waiters(store(), key(), [opt()]) :: [String.t()] | :unknown
  def waiters(store, key, opts \\ []) do
    store_mod = Run.store_module(engine_opts(opts))

    if function_exported?(store_mod, :waiters, 2) do
      store_mod
      |> apply(:waiters, [store, key])
      |> Enum.filter(&(&1.kind == :signal))
      |> Enum.map(& &1.name)
    else
      :unknown
    end
  end

  # -- internals ---------------------------------------------------------------

  # The provider's `status/2` exposes exactly this detail shape; `run_status` in
  # it is the honest underlying label behind the A2A state.
  defp ended_state(store, key, opts) do
    case Engine.fetch(store, key, engine_opts(opts)) do
      nil -> {:error, :no_such_run}
      %{status: status} = record -> {:ok, to_state!(status), record.result}
    end
  end

  # The resume signal name: explicit opt wins; else the single parked signal
  # waiter's name; else a typed refusal (never a guessed broadcast).
  defp signal_name(store, key, opts) do
    case opts[:signal] do
      nil ->
        case waiters(store, key, opts) do
          [name] -> {:ok, name}
          [] -> {:error, :no_signal_waiter}
          names -> {:error, {:ambiguous_waiters, names}}
        end

      name when is_binary(name) ->
        {:ok, name}

      other ->
        {:error, {:invalid_signal, other}}
    end
  end

  defp engine_opts(opts), do: Keyword.take(opts, [:store_module, :claimer, :lease_ms])

  defp wrap_inputs(%{input: _} = inputs), do: inputs
  defp wrap_inputs(inputs) when is_map(inputs), do: %{input: inputs}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_state!(status) do
    case to_state(status) do
      {:ok, state} -> state
      {:error, reason} -> raise ArgumentError, "unmapped ash_pplan run status: #{inspect(reason)}"
    end
  end
end
