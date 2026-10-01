defmodule AshPPlan.Reactor.Durable.Engine do
  @moduledoc """
  The durable run lifecycle over a `AshPPlan.Reactor.Durable.Store`.

  An attempt claims the run with a lease, replays it through `Run`, maps the Reactor outcome to a
  guarded status transition, and releases the claim only AFTER the outcome is written, so a
  delivery landing in between sees a held run. A terminal run is never re-run; a late attempt can
  not overwrite `:cancelling`/`:unwinding` (transitions are guarded by `from`).

  Scheduling is level-triggered: `runnable?/3` reads state (pending, an unconsumed signal, a
  due waiter, a rollback nobody holds, a lapsed claim); no wake-up message has to survive.
  Every function takes the store first; pass `store_module: mod` in opts to use a store other
  than `AshPPlan.Reactor.Durable.Store.Ets`.

  Design derived from mbuhot/magma (MIT per its mix.exs), re-implemented.
  """

  alias AshPPlan.Reactor.Durable.{Clock, Key, PolicyDriver, Run, Status, Unwind}

  @lease_ms 30_000

  @type outcome ::
          {:completed, term()}
          | {:parked, atom()}
          | {:failed, term()}
          | {:rolled_back, atom()}
          | {:refused, term()}
          | :taken
          | :ended
          | :not_found

  @doc "Default claim lease in ms."
  def lease_ms, do: @lease_ms

  @doc "Start a run. Idempotent by `attrs.id`: an existing run is returned unchanged."
  @spec start(term(), map(), keyword()) :: {:ok, AshPPlan.Reactor.Durable.Record.t()}
  def start(store, attrs, opts \\ []) do
    mod = Run.store_module(opts)
    attrs = attrs |> Map.put_new_lazy(:id, &new_id/0) |> defaults()

    case mod.start_run(store, attrs) do
      {:ok, record} -> {:ok, record}
      {:error, :exists} -> {:ok, mod.get_run(store, attrs.id)}
    end
  end

  defp defaults(attrs) do
    attrs
    |> Map.put_new(:bindings, %{})
    |> Map.put_new(:inputs, %{})
    |> Map.put_new(:context, %{})
  end

  defp new_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    hex = fn n, w ->
      n |> Integer.to_string(16) |> String.pad_leading(w, "0") |> String.downcase()
    end

    Enum.join([hex.(a, 8), hex.(b, 4), hex.(c, 4), hex.(d, 4), hex.(e, 12)], "-")
  end

  @doc "One claimed attempt at a run. See the module doc and `t:outcome/0`."
  @spec attempt(term(), String.t(), keyword()) :: outcome()
  def attempt(store, run_id, opts \\ []) do
    case admit_policy(opts) do
      :ok -> do_attempt(store, run_id, opts)
      {:error, reason} -> {:refused, reason}
    end
  end

  # Option `policy: driver` is gated before the run is even read: no claim, no effect.
  defp admit_policy(opts) do
    case Keyword.get(opts, :policy) do
      nil -> :ok
      driver -> PolicyDriver.admit(driver)
    end
  end

  defp do_attempt(store, run_id, opts) do
    mod = Run.store_module(opts)

    case mod.get_run(store, run_id) do
      nil ->
        :not_found

      %{status: status} = _record ->
        if Status.terminal?(status) do
          mod.release_all(store, run_id)
          :ended
        else
          claim_and_run(mod, store, run_id, opts)
        end
    end
  end

  defp claim_and_run(mod, store, run_id, opts) do
    claimer = Keyword.get_lazy(opts, :claimer, fn -> "claim-" <> new_id() end)
    lease = Keyword.get(opts, :lease_ms, @lease_ms)

    case mod.claim(store, run_id, claimer, lease, Clock.now()) do
      :taken ->
        :taken

      {:ok, claimed} ->
        try do
          drive(mod, store, mod.get_run(store, run_id) || claimed, opts)
        after
          mod.release_claim(store, run_id, claimer)
        end
    end
  end

  defp drive(mod, store, %{status: status} = record, opts) do
    cond do
      Status.terminal?(status) -> :ended
      Status.rolling_back?(status) -> rollback(mod, store, record, opts)
      status == :unwind_blocked -> rollback(mod, store, record, opts)
      true -> forward(mod, store, record, opts)
    end
  end

  defp forward(mod, store, record, opts) do
    run_opts = Keyword.put(opts, :store_module, mod)

    outcome =
      try do
        Run.run(store, record, run_opts)
      rescue
        e -> {:error, e}
      end

    case reload(mod, store, record) do
      {:ended, _} -> :ended
      {:rolling_back, current} -> rollback(mod, store, current, opts)
      {:ok, current} -> settle(mod, store, current, outcome)
    end
  end

  # An ending stands; a rollback under way is never rolled forward again.
  defp reload(mod, store, record) do
    case mod.get_run(store, record.id) do
      nil -> {:ended, record}
      %{status: s} = cur -> reload_status(s, cur)
    end
  end

  defp reload_status(s, cur) do
    cond do
      Status.terminal?(s) -> {:ended, cur}
      s in [:cancelling] -> {:rolling_back, cur}
      true -> {:ok, cur}
    end
  end

  defp settle(mod, store, record, {:ok, result}) do
    case mod.transition(
           store,
           record.id,
           [:pending, :waiting, :polling, :unwinding],
           :completed,
           %{
             result: result
           }
         ) do
      {:ok, ended} ->
        finish(mod, store, ended, {:completed, result})

      {:error, _} ->
        :ended
    end
  end

  defp settle(mod, store, record, {:halted, _reactor}) do
    to =
      if Enum.any?(mod.waiters(store, record.id), &(&1.kind == :poll)),
        do: :polling,
        else: :waiting

    case mod.transition(store, record.id, [:pending, :waiting, :polling], to, %{}) do
      {:ok, _} -> {:parked, to}
      {:error, _} -> {:parked, record.status}
    end
  end

  defp settle(mod, store, record, {:error, error}) do
    # The cause recorded by the middleware before the rollback began, if any, is the cause.
    cause = (record.status == :unwinding && record.error) || error

    case mod.transition(store, record.id, [:pending, :waiting, :polling, :unwinding], :failed, %{
           error: cause
         }) do
      {:ok, ended} -> finish(mod, store, ended, {:failed, cause})
      {:error, _} -> :ended
    end
  end

  defp finish(mod, store, ended, result) do
    mod.release_all(store, ended.id)
    report_to_parent(mod, store, ended)
    result
  end

  # Driven from the checkpoints, not replayed: finish what a rollback left standing.
  defp rollback(mod, store, record, opts) do
    intent = if record.status == :unwind_blocked, do: record.intent, else: record.status
    ending = if intent == :cancelling, do: :cancelled, else: :failed

    case Unwind.run(store, record.id, Keyword.put(opts, :store_module, mod)) do
      {:ok, _unresolved} ->
        attrs = if ending == :failed, do: %{error: record.error || :unwound}, else: %{}

        case mod.transition(store, record.id, [record.status], ending, attrs) do
          {:ok, ended} ->
            mod.release_all(store, ended.id)
            report_to_parent(mod, store, ended)
            {:rolled_back, ending}

          {:error, _} ->
            :ended
        end

      {:error, errors} ->
        _ =
          mod.transition(store, record.id, [record.status], :unwind_blocked, %{
            error: errors,
            intent: intent
          })

        {:failed, errors}
    end
  end

  defp report_to_parent(mod, store, %{parent_id: pid, parent_signal: sig} = ended)
       when not is_nil(pid) and not is_nil(sig) do
    mod.deliver_signal(store, pid, sig, %{child_id: ended.id, status: ended.status})
    :ok
  end

  defp report_to_parent(_mod, _store, _ended), do: :ok

  @max_policy_steps 1_000

  @doc """
  Drive a run by a FOND policy instead of sealing a step and picking the next by position.

  Options: `policy:` (a `PolicyDriver`, required), `execute:` (`fn action, ctx -> {:ok, observed}`
  where `observed` is the FOND state the action produced; `ctx` carries `:run_id`, `:step`,
  `:state`), `max_steps:`, `claimer:`, `lease_ms:`.

  Each observed outcome is checked against the domain, then one decision is written to the
  ledger (a standing checkpoint keyed by decision index holding the `policy` fingerprint,
  `from`, `action`, `observed`). On replay a recorded decision is read, not executed again, and
  it must still be what the policy decides: a different policy or action is
  `{:refused, {:policy_replay_divergence, detail}}`. Refusals leave the run non-terminal:

    * `{:refused, {:inadmissible_policy, _}}` - before the claim, nothing executed
    * `{:refused, {:outcome_outside_policy_domain, _}}` - an outcome the domain does not admit
    * `{:refused, {:policy_replay_divergence, _}}`

  Reaching a goal completes the run with `%{goal: state, decisions: [...]}`. The policy grants no
  authority: it only names the next action; `execute:` is the caller's.
  """
  @spec drive_policy(term(), String.t(), keyword()) :: outcome()
  def drive_policy(store, run_id, opts) do
    mod = Run.store_module(opts)
    driver = Keyword.fetch!(opts, :policy)
    execute = Keyword.fetch!(opts, :execute)

    with :ok <- PolicyDriver.admit(driver),
         %{status: status} <- mod.get_run(store, run_id) do
      if Status.terminal?(status) do
        :ended
      else
        claim_policy(mod, store, run_id, driver, execute, opts)
      end
    else
      nil -> :not_found
      {:error, reason} -> {:refused, reason}
    end
  end

  defp claim_policy(mod, store, run_id, driver, execute, opts) do
    claimer = Keyword.get_lazy(opts, :claimer, fn -> "claim-" <> new_id() end)
    lease = Keyword.get(opts, :lease_ms, @lease_ms)

    case mod.claim(store, run_id, claimer, lease, Clock.now()) do
      :taken ->
        :taken

      {:ok, _} ->
        try do
          env = %{
            mod: mod,
            store: store,
            id: run_id,
            driver: driver,
            execute: execute,
            ledger: mod.checkpoints(store, run_id),
            limit: Keyword.get(opts, :max_steps, @max_policy_steps)
          }

          policy_loop(env, driver.initial, 0, [])
        after
          mod.release_claim(store, run_id, claimer)
        end
    end
  end

  defp policy_loop(%{limit: limit}, _state, n, _acc) when n >= limit,
    do: {:refused, {:policy_step_limit, limit}}

  defp policy_loop(env, state, n, acc) do
    case PolicyDriver.decide(env.driver, state) do
      {:done, goal} ->
        finish_policy(env, goal, Enum.reverse(acc))

      {:error, reason} ->
        {:refused, reason}

      {:ok, action} ->
        key = Key.for_name({:policy_decision, n})

        case Map.get(env.ledger, key) do
          nil -> fresh_decision(env, {state, action, n, key}, acc)
          cp -> replay_decision(env, {state, action, n}, cp, acc)
        end
    end
  end

  defp fresh_decision(env, {state, action, n, key}, acc) do
    with {:ok, observed} <- env.execute.(action, %{run_id: env.id, step: n, state: state}),
         {:ok, observed} <- PolicyDriver.observe(env.driver, state, action, observed) do
      decision = decision(env.driver, n, state, action, observed)

      case env.mod.record(env.store, env.id, key, "policy-decision:#{n}", decision, %{
             name: {:policy_decision, n}
           }) do
        {:ok, cp} -> policy_loop(env, cp.output.observed, n + 1, [cp.output | acc])
        {:error, :terminal} -> :ended
      end
    else
      {:error, {:outcome_outside_policy_domain, _} = reason} -> {:refused, reason}
      other -> {:failed, {:policy_execute_failed, other}}
    end
  end

  defp replay_decision(env, {state, action, n}, cp, acc) do
    rec = cp.output
    fp = PolicyDriver.fingerprint(env.driver)

    if rec.policy == fp and rec.from == state and rec.action == action do
      policy_loop(env, rec.observed, n + 1, [rec | acc])
    else
      {:refused,
       {:policy_replay_divergence,
        %{step: n, recorded: rec, decided: %{from: state, action: action, policy: fp}}}}
    end
  end

  defp decision(driver, n, from, action, observed),
    do: %{
      step: n,
      policy: PolicyDriver.fingerprint(driver),
      from: from,
      action: action,
      observed: observed
    }

  defp finish_policy(env, goal, decisions) do
    result = %{goal: goal, decisions: decisions}

    case env.mod.transition(env.store, env.id, [:pending, :waiting, :polling], :completed, %{
           result: result
         }) do
      {:ok, ended} -> finish(env.mod, env.store, ended, {:completed, result})
      {:error, _} -> :ended
    end
  end

  @doc "Deliver a signal to a run (consume-once, FIFO per name)."
  @spec signal(term(), String.t(), String.t(), term(), keyword()) ::
          {:ok, AshPPlan.Reactor.Durable.Signal.t()}
  def signal(store, run_id, name, payload, opts \\ []),
    do: Run.store_module(opts).deliver_signal(store, run_id, name, payload)

  @doc """
  Make a parked run's status honest: a parked run that is runnable now goes back to `:pending`.
  Scheduling itself is level-triggered, so this only moves the label.
  """
  @spec wake(term(), String.t(), keyword()) :: :ok | :ended | :not_found
  def wake(store, run_id, opts \\ []) do
    mod = Run.store_module(opts)

    case mod.get_run(store, run_id) do
      nil ->
        :not_found

      %{status: s} = r ->
        cond do
          Status.terminal?(s) ->
            :ended

          Status.parked?(s) and runnable?(store, r, Clock.now(), opts) ->
            _ = mod.transition(store, run_id, [s], :pending, %{})
            :ok

          true ->
            :ok
        end
    end
  end

  @doc """
  Cancel a run (from pending|waiting|polling), propagating to its non-terminal children.

  Cancel CLAIMS the run (claimer `cancel-...`) before transitioning, so it serializes against
  `Migration.apply`'s `migration-...` claim through the store's claim CAS: whichever wins,
  the loser gets `:taken`. A cancel that loses the race is refused with
  `{:error, {:claim_held, run_id}}`; a migration that loses simply never starts. Cancelling an
  in-flight ATTEMPT is unaffected: the attempt's claim does not block a cancel.
  """
  @spec cancel(term(), String.t(), keyword()) ::
          {:ok, AshPPlan.Reactor.Durable.Record.t()}
          | {:error, :no_such_run | :not_cancellable | {:claim_held, String.t()}}
  def cancel(store, run_id, opts \\ []) do
    mod = Run.store_module(opts)
    claimer = "cancel-" <> inspect(self())

    case mod.get_run(store, run_id) do
      nil ->
        {:error, :no_such_run}

      %{status: s} = record ->
        cond do
          not Status.cancellable?(s) ->
            {:error, :not_cancellable}

          match?(%{claimed_by: <<"migration-", _::binary>>}, record) ->
            # Fast path: the stale read already shows a migration claim; skip the CAS.
            {:error, {:claim_held, run_id}}

          true ->
            case mod.claim(store, run_id, claimer, @lease_ms, Clock.now()) do
              :taken ->
                # The CAS lost: re-read to learn who holds the claim now. A live MIGRATION
                # claim wins exclusively; an in-flight ATTEMPT claim does not (cancel
                # mid-attempt wins and the attempt's forward transitions then fail on the
                # status guard).
                re = mod.get_run(store, run_id)

                if match?(%{claimed_by: <<"migration-", _::binary>>}, re),
                  do: {:error, {:claim_held, run_id}},
                  else: {:steal, re}

              {:ok, claimed} ->
                {:claimed, claimed}

              other ->
                other
            end
            |> case do
              {:steal, _re} ->
                # Not ours and not a migration: an in-flight attempt held it. Cancel wins
                # (the attempt's forward transitions then fail on the status guard); the
                # foreign claim is left alone.
                cancel_transition(mod, store, run_id, opts)

              {:claimed, _claimed} ->
                try do
                  cancel_transition(mod, store, run_id, opts)
                after
                  mod.release_claim(store, run_id, claimer)
                end
            end
        end
    end
  end

  defp cancel_transition(mod, store, run_id, opts) do
    case mod.transition(store, run_id, [:pending, :waiting, :polling], :cancelling, %{}) do
      {:ok, rec} ->
        cancel_children(mod, store, run_id, opts)
        {:ok, rec}

      {:error, _} ->
        {:error, :not_cancellable}
    end
  end

  defp cancel_children(mod, store, run_id, opts) do
    for %{id: id} <- mod.list_runs(store), child_of?(mod, store, id, run_id) do
      cancel(store, id, opts)
    end

    :ok
  end

  defp child_of?(mod, store, id, parent_id) do
    match?(%{parent_id: ^parent_id}, mod.get_run(store, id))
  end

  @doc "Fetch a run record (or nil)."
  def fetch(store, id, opts \\ []), do: Run.store_module(opts).get_run(store, id)

  @doc "Standing checkpoints of a run, in checkpoint order."
  def steps(store, run_id, opts \\ []), do: Run.store_module(opts).standing(store, run_id)

  @doc "Level-triggered: should an attempt at this run do anything at `now`?"
  @spec runnable?(term(), AshPPlan.Reactor.Durable.Record.t(), DateTime.t(), keyword()) ::
          boolean()
  def runnable?(store, record, now, opts \\ []) do
    mod = Run.store_module(opts)
    s = record.status

    cond do
      Status.terminal?(s) or s == :unwind_blocked ->
        false

      held?(record, now, opts) ->
        false

      Status.rolling_back?(s) ->
        true

      record.claimed_at != nil ->
        true

      s == :pending ->
        true

      Status.parked?(s) ->
        signal_waiting?(mod, store, record) or waiter_due?(mod, store, record, now)

      true ->
        false
    end
  end

  defp held?(%{claimed_at: nil}, _now, _opts), do: false

  defp held?(%{claimed_at: at}, now, opts) do
    lease = Keyword.get(opts, :lease_ms, @lease_ms)
    DateTime.compare(now, Clock.add(at, lease)) == :lt
  end

  defp signal_waiting?(mod, store, record),
    do: Enum.any?(mod.signals(store, record.id), &is_nil(&1.consumed_at))

  defp waiter_due?(mod, store, record, now) do
    Enum.any?(mod.waiters(store, record.id), fn w ->
      w.deadline != nil and DateTime.compare(w.deadline, now) != :gt
    end)
  end

  @doc "Ids of runnable runs at `now`, ordered by seq."
  @spec runnable(term(), DateTime.t(), keyword()) :: [String.t()]
  def runnable(store, now, opts \\ []) do
    mod = Run.store_module(opts)

    store
    |> mod.list_runs()
    |> Enum.filter(&runnable?(store, &1, now, opts))
    |> Enum.sort_by(& &1.seq)
    |> Enum.map(& &1.id)
  end
end
