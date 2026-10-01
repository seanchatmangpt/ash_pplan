defmodule AshPPlan.Reactor.Durable.Counterfactual do
  @moduledoc """
  Counterfactual replay from the ledger: "what would have happened had X been different".

  `replay/3` re-runs a recorded durable run in a private scratch store, against the outputs the
  original run recorded, with one change applied. The original run is only ever READ: its ledger
  digest (`ledger_digest/3`) is identical before and after, and the scratch store is a separate
  process. Re-executed steps run for real inside the scratch run (the effects of a replayed step
  happen again), so the ceiling stays `:construct`; nothing here grants DO authority.

  ## Changes

    * `%{provider: %{task_id => %AshPPlan.Realization{} | provider_module}}` - rebind a task. A
      provider module is resolved through a one-provider `AshPPlan.Providers.Registry`; an
      unresolvable one is a typed refusal. The task and every task downstream of it re-execute.
    * `%{policy: %{task_id => %{field => value}}}` - override model task fields (authority,
      properties, evidence, ...) and re-validate the model. The policy is also placed in the
      run context as `:policy`. The task and its dependents re-execute.
    * `%{outputs: %{task_id => value}}` - substitute the recorded output of a task. The task is
      not executed (its checkpoint is the substituted value); its dependents re-execute. This is
      how a failed run is replayed "as if the failing step had produced X".

  The recorded checkpoints of every task outside the invalidated set (even ones the original
  run later took back while unwinding) are copied into the scratch run, and the original run's
  signals are re-delivered, so only the changed cone re-runs.

  ## Result

  `{:ok, %{original:, counterfactual:, diff:, scratch:}}` where `original`/`counterfactual` are
  `%{status:, result:, events:, ocel:}` (`events` are `AshPPlan.ProcessEvidence.Event` lists with
  deterministic timestamps derived from checkpoint order, `ocel` the OCEL 2.0 JSON export) and
  `diff` is

      %{events: %{added: [id], removed: [id], changed: [%{id:, before:, after:}]},
        tasks_reexecuted: [task_id],
        outcome: %{before:, after:, changed?:},
        standing: %{before:, after:, changed?:},
        result: %{before:, after:, changed?:},
        empty?: boolean}

  `empty?` is true when events, outcome and standing are all unchanged (the result term is
  reported but excluded, since a re-executed counting effect legitimately yields a new value).
  `standing` is `:standing` only when the run completed with every task checkpointed and none
  taken back.

  Options: `:store_module`, `:scratch` (an existing scratch store; default a fresh
  `Store.Ets`), `:keep` (keep the scratch store alive and return it, default stops it),
  `:attempts` (engine attempts in the scratch run, default 3: more than one lets a run that
  stopped at a re-delivered signal finish).

  Deterministic: the same ledger and change yield the same diff.
  """

  alias AshPPlan.{ExecutionReceipt, ProcessEvidence, Realization}
  alias AshPPlan.Providers.Registry
  alias AshPPlan.Reactor.Durable.{Engine, Key, Run}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Workflow.{Model, Subject}
  alias AshPPlan.Workflow.Project.Reactor, as: ProjectReactor

  @epoch ~U[2000-01-01 00:00:00Z]

  @type change :: %{
          optional(:provider) => map(),
          optional(:policy) => map(),
          optional(:outputs) => map()
        }

  @doc """
  Digest of everything the ledger holds for `run_id` (run record, checkpoints, signals, waiters).
  Equal digests before and after a replay prove the original was left untouched.
  """
  @spec ledger_digest(term(), String.t(), keyword()) :: binary()
  def ledger_digest(store, run_id, opts \\ []) do
    mod = Run.store_module(opts)

    term = {
      mod.get_run(store, run_id),
      store |> mod.checkpoints(run_id) |> Enum.sort(),
      store |> mod.signals(run_id) |> Enum.sort_by(& &1.seq),
      store |> mod.waiters(run_id) |> Enum.sort_by(& &1.name)
    }

    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
  end

  @doc "Replay `run_id` of `store` with the change `opts[:change]` (see the moduledoc)."
  @spec replay(term(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def replay(store, run_id, opts) do
    mod = Run.store_module(opts)
    change = opts |> Keyword.get(:change, %{}) |> Map.new()

    with %{} = record <- mod.get_run(store, run_id) || {:error, :run_not_found},
         {:ok, plan} <- plan_change(record, change) do
      do_replay(mod, store, record, plan, opts)
    else
      {:error, :run_not_found} -> {:error, %{reason: :run_not_found, run_id: run_id}}
      {:error, detail} -> {:error, %{reason: :invalid_change, detail: detail}}
    end
  end

  # ---- change planning -------------------------------------------------------------------

  defp plan_change(record, change) do
    with :ok <- known_keys(change),
         {:ok, bindings, provider_tasks} <- apply_providers(record, Map.get(change, :provider)),
         {:ok, model, policy_tasks} <- apply_policy(record.model, Map.get(change, :policy)),
         {:ok, overrides} <- outputs(model, Map.get(change, :outputs)) do
      invalidated = closure(model, provider_tasks ++ policy_tasks ++ Map.keys(overrides))
      reexec = invalidated -- Map.keys(overrides)

      {:ok,
       %{
         model: model,
         bindings: bindings,
         policy: Map.get(change, :policy),
         overrides: overrides,
         invalidated: invalidated,
         reexec: reexec
       }}
    end
  end

  defp known_keys(change) do
    case Map.keys(change) -- [:provider, :policy, :outputs] do
      [] -> :ok
      unknown -> {:error, {:unknown_change, unknown}}
    end
  end

  defp apply_providers(record, nil), do: {:ok, record.bindings || %{}, []}

  defp apply_providers(record, swaps) when is_map(swaps) do
    tasks = Map.new(record.model.tasks, &{&1.id, &1})

    Enum.reduce_while(swaps, {:ok, record.bindings || %{}, []}, fn {id, target}, {:ok, b, ids} ->
      with %{} = task <- Map.get(tasks, id) || {:error, {:unknown_task, id}},
           {:ok, realization} <- realization(task, target) do
        {:cont, {:ok, Map.put(b, id, realization), [id | ids]}}
      else
        {:error, detail} -> {:halt, {:error, detail}}
      end
    end)
    |> case do
      {:ok, b, ids} -> {:ok, b, Enum.sort(ids)}
      error -> error
    end
  end

  defp apply_providers(_record, other), do: {:error, {:bad_provider_change, other}}

  defp realization(_task, %Realization{} = r), do: {:ok, r}

  defp realization(task, mod) when is_atom(mod) and not is_nil(mod) do
    requirement = %{
      capability: task.capability,
      properties: Enum.map(task.properties, &atomize/1),
      evidence: Enum.map(task.evidence, &atomize/1),
      authority: resolver_authority(task.authority),
      options: []
    }

    case Registry.resolve(Registry.new([mod]), requirement, %{ceiling: :construct}) do
      {:ok, r} -> {:ok, r.realization}
      {:error, detail} -> {:error, {:provider_refused, task.id, mod, detail}}
    end
  end

  defp realization(_task, other), do: {:error, {:bad_provider, other}}

  defp resolver_authority(a) when a in [:select, :plan], do: :observe
  defp resolver_authority(a), do: a

  defp atomize(v) when is_binary(v) do
    String.to_existing_atom(v)
  rescue
    ArgumentError -> v
  end

  defp atomize(v), do: v

  defp apply_policy(model, nil), do: {:ok, model, []}

  defp apply_policy(model, policy) when is_map(policy) do
    ids = Enum.map(model.tasks, & &1.id)

    case Map.keys(policy) -- ids do
      [] ->
        tasks =
          Enum.map(model.tasks, fn t ->
            case Map.get(policy, t.id) do
              nil -> t
              fields -> struct_or_merge(t, Map.new(fields))
            end
          end)

        model = %{model | tasks: tasks}

        case Model.validate(model) do
          :ok -> {:ok, model, Enum.sort(Map.keys(policy))}
          {:error, detail} -> {:error, {:policy_invalid, detail}}
        end

      unknown ->
        {:error, {:unknown_task, unknown}}
    end
  end

  defp apply_policy(_model, other), do: {:error, {:bad_policy_change, other}}

  defp struct_or_merge(%{__struct__: _} = t, fields), do: struct(t, fields)
  defp struct_or_merge(t, fields), do: Map.merge(t, fields)

  defp outputs(_model, nil), do: {:ok, %{}}

  defp outputs(model, outs) when is_map(outs) do
    case Map.keys(outs) -- Enum.map(model.tasks, & &1.id) do
      [] -> {:ok, outs}
      unknown -> {:error, {:unknown_task, unknown}}
    end
  end

  defp outputs(_model, other), do: {:error, {:bad_outputs_change, other}}

  # The changed tasks plus every task that transitively depends on one of them.
  defp closure(model, seeds) do
    grow(MapSet.new(seeds), model.tasks)
    |> MapSet.to_list()
    |> Enum.sort_by(&order_index(model, &1))
  end

  defp grow(set, tasks) do
    next =
      Enum.reduce(tasks, set, fn t, acc ->
        if Enum.any?(t.depends_on, &MapSet.member?(acc, &1)), do: MapSet.put(acc, t.id), else: acc
      end)

    if MapSet.equal?(next, set), do: set, else: grow(next, tasks)
  end

  defp order_index(model, id) do
    {:ok, order} = Model.topological_order(model)
    Enum.find_index(order, &(&1 == id))
  end

  # ---- replay ----------------------------------------------------------------------------

  defp do_replay(mod, store, record, plan, opts) do
    {scratch, owned?} = scratch_store(opts)

    try do
      before = ledger_digest(store, record.id, store_module: mod)
      original = observe(mod, store, record)

      with {:ok, seeded} <- seed(mod, store, record, scratch, plan),
           :ok <- redeliver_signals(mod, store, record, scratch) do
        attempts = Keyword.get(opts, :attempts, 3)
        run_scratch(scratch, record.id, attempts, store_module: mod)

        scratch_record = mod.get_run(scratch, record.id)
        counterfactual = observe(mod, scratch, scratch_record)

        result = %{
          original: original,
          counterfactual: counterfactual,
          diff: diff(original, counterfactual, plan, seeded, mod, scratch, scratch_record),
          untouched?: ledger_digest(store, record.id, store_module: mod) == before,
          scratch: if(opts[:keep], do: scratch)
        }

        {:ok, result}
      else
        {:error, detail} -> {:error, %{reason: :replay_failed, detail: detail}}
      end
    after
      if owned? and not Keyword.get(opts, :keep, false) and is_pid(scratch) and
           Process.alive?(scratch),
         do: GenServer.stop(scratch)
    end
  end

  defp scratch_store(opts) do
    case Keyword.get(opts, :scratch) do
      nil ->
        {:ok, pid} = Ets.start_link()
        {pid, true}

      store ->
        {store, false}
    end
  end

  defp run_scratch(scratch, run_id, attempts, eopts) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      outcome = Engine.attempt(scratch, run_id, eopts)

      case outcome do
        {:parked, _} -> {:cont, outcome}
        :taken -> {:cont, outcome}
        _ -> {:halt, outcome}
      end
    end)
  end

  defp seed(mod, store, record, scratch, plan) do
    attrs = %{
      id: record.id,
      plan_iri: record.plan_iri,
      model: plan.model,
      bindings: plan.bindings,
      inputs: record.inputs,
      context:
        if(plan.policy,
          do: Map.put(record.context || %{}, :policy, plan.policy),
          else: record.context || %{}
        ),
      intent: record.intent
    }

    {:ok, scratch_record} = Engine.start(scratch, attrs, store_module: mod)

    with {:ok, keys} <- task_keys(scratch_record, plan.model) do
      stale = MapSet.new(Enum.map(plan.invalidated, &key_of(keys, &1)))

      recorded =
        store |> mod.checkpoints(record.id) |> Map.values() |> Enum.sort_by(& &1.seq)

      copied =
        for cp <- recorded, not MapSet.member?(stale, cp.step_key) do
          {:ok, _} =
            mod.record(scratch, record.id, cp.step_key, cp.label, cp.output, meta(cp))

          cp.step_key
        end

      substituted =
        for {id, value} <- Enum.sort(plan.overrides) do
          {key, name} = Map.fetch!(keys, id)
          {:ok, _} = mod.record(scratch, record.id, key, Key.label(name), value, %{name: name})
          key
        end

      {:ok, MapSet.new(copied ++ substituted)}
    end
  end

  defp meta(cp), do: %{impl: cp.impl, args: cp.args, name: cp.name}

  defp key_of(keys, id), do: keys |> Map.fetch!(id) |> elem(0)

  # task id => step key, from the reactor the scratch run will actually execute.
  defp task_keys(scratch_record, model) do
    with {:ok, reactor} <- Run.reactor_for(scratch_record) do
      names = Map.new(reactor.steps, &{to_string(&1.name), &1.name})

      Enum.reduce_while(model.tasks, {:ok, %{}}, fn t, {:ok, acc} ->
        iri = ProjectReactor.step_iri(model, t.id)

        case Map.fetch(names, iri) do
          {:ok, name} -> {:cont, {:ok, Map.put(acc, t.id, {Key.for_name(name), name})}}
          :error -> {:halt, {:error, {:no_step_for_task, t.id}}}
        end
      end)
    end
  end

  defp redeliver_signals(mod, store, record, scratch) do
    store
    |> mod.signals(record.id)
    |> Enum.sort_by(& &1.seq)
    |> Enum.each(fn s ->
      {:ok, _} = mod.deliver_signal(scratch, record.id, s.name, s.payload)
    end)

    :ok
  end

  # ---- observation -----------------------------------------------------------------------

  defp observe(mod, store, record) do
    %{status: status} = record
    cps = store |> mod.checkpoints(record.id) |> Map.values() |> Enum.sort_by(& &1.seq)
    events = events(mod, store, record, cps)
    {:ok, ocel} = ProcessEvidence.export(events, :ocel2_json)

    %{
      status: status,
      result: record.result,
      standing: standing(record, cps),
      events: events,
      ocel: ocel,
      checkpoints: Enum.map(cps, & &1.label)
    }
  end

  defp standing(%{status: :completed, model: model}, cps) do
    reached = cps |> Enum.reject(& &1.undone_at) |> length()
    if reached >= length(model.tasks), do: :standing, else: :not_standing
  end

  defp standing(_record, _cps), do: :not_standing

  defp events(_mod, _store, record, cps) do
    model = record.model
    subject = Subject.bind(model)
    {:ok, order} = Model.topological_order(model)
    by_id = Map.new(model.tasks, &{&1.id, &1})
    {:ok, keys} = task_keys(record, model)
    by_key = Map.new(cps, &{&1.step_key, &1})
    rank = cps |> Enum.with_index(1) |> Map.new(fn {cp, i} -> {cp.step_key, i} end)
    done = for id <- order, Map.has_key?(by_key, key_of(keys, id)), do: id
    failed = failed_task(record, order, by_id, done)

    reals =
      Map.new(model.tasks, fn t ->
        {t.id, to_string(provider(record.bindings, t.id))}
      end)

    Enum.flat_map(order, fn id ->
      task = Map.fetch!(by_id, id)
      cp = Map.get(by_key, key_of(keys, id))
      status = task_status(id, cp, failed)

      case status do
        nil ->
          []

        s ->
          at =
            DateTime.add(
              @epoch,
              if(cp, do: Map.fetch!(rank, cp.step_key), else: length(cps) + 1),
              :second
            )

          receipt = %ExecutionReceipt{
            plan_iri: record.plan_iri || "urn:ash-pplan:workflow:#{model.name}",
            run_id: record.id,
            status: s,
            started_at: at,
            finished_at: at,
            duration_us: 0,
            outcome_digest: "counterfactual"
          }

          ProcessEvidence.events_from_receipt(receipt, subject,
            tasks: [task],
            realizations: reals,
            failed_task: if(s == :failed, do: id)
          )
      end
    end)
  end

  defp provider(bindings, id) do
    case Map.get(bindings || %{}, id) do
      %{provider: p} -> p
      _ -> :unbound
    end
  end

  defp task_status(id, cp, failed) do
    cond do
      cp != nil -> :succeeded
      id == failed -> :failed
      true -> nil
    end
  end

  # A failed task is the first not-yet-checkpointed task whose dependencies all stand, for a
  # run that did not complete. Parked runs have no failed task.
  defp failed_task(%{status: status}, _order, _by_id, _done)
       when status in [:completed, :pending, :waiting, :polling],
       do: nil

  defp failed_task(%{error: error}, order, by_id, done) do
    candidates =
      for id <- order,
          id not in done,
          Enum.all?(by_id[id].depends_on, &(&1 in done)),
          do: id

    text = inspect(error, limit: :infinity, printable_limit: 100_000)

    Enum.find(candidates, fn id -> String.contains?(text, to_string(id)) end) ||
      List.first(candidates)
  end

  # ---- diff ------------------------------------------------------------------------------

  defp diff(original, counterfactual, plan, seeded, mod, scratch, scratch_record) do
    before = Map.new(original.events, &{&1.id, &1})
    after_ = Map.new(counterfactual.events, &{&1.id, &1})

    added = after_ |> Map.keys() |> Kernel.--(Map.keys(before)) |> Enum.sort()
    removed = before |> Map.keys() |> Kernel.--(Map.keys(after_)) |> Enum.sort()

    changed =
      for {id, b} <- Enum.sort(before),
          a = Map.get(after_, id),
          a != nil,
          view(a) != view(b),
          do: %{id: id, before: view(b), after: view(a)}

    events = %{added: added, removed: removed, changed: changed}

    {:ok, keys} = task_keys(scratch_record, plan.model)
    scratch_cps = scratch |> mod.checkpoints(scratch_record.id) |> Map.values()

    ran =
      MapSet.new(for cp <- scratch_cps, not MapSet.member?(seeded, cp.step_key), do: cp.step_key)

    reexecuted =
      for t <- plan.model.tasks,
          key_of(keys, t.id) in ran or t.id in failed_in(counterfactual, scratch_record),
          t.id in plan.reexec,
          do: t.id

    outcome = pair(original.status, counterfactual.status)
    standing = pair(original.standing, counterfactual.standing)
    result = pair(original.result, counterfactual.result)

    %{
      events: events,
      tasks_reexecuted: Enum.sort_by(reexecuted, &order_index(plan.model, &1)),
      outcome: outcome,
      standing: standing,
      result: result,
      empty?:
        added == [] and removed == [] and changed == [] and not outcome.changed? and
          not standing.changed?
    }
  end

  defp failed_in(counterfactual, record) do
    ids = for e <- counterfactual.events, e.activity == "task_failed", do: e.attributes.task
    ids = MapSet.new(ids)
    for t <- record.model.tasks, MapSet.member?(ids, to_string(t.id)), do: t.id
  end

  defp view(e), do: {e.activity, Enum.sort(e.objects), e.attributes}

  defp pair(a, b), do: %{before: a, after: b, changed?: a != b}
end
