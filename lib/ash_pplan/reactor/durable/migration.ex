defmodule AshPPlan.Reactor.Durable.Migration.Plan do
  @moduledoc """
  Pure result of `AshPPlan.Reactor.Durable.Migration.plan/3`: how the tasks (and therefore the
  checkpoint keys) of one workflow model correspond to those of another.

  `steps` lists one entry per OLD task: its step name and `Key.for_name/1` key under the old
  model, and (when the task survives, directly or by rename) the same under the new model.
  Grants no authority; it is data.
  """
  @enforce_keys [:old_subject, :new_subject]
  defstruct schema: "ash_pplan/durable-migration-plan/v1",
            old_subject: nil,
            new_subject: nil,
            old_model: nil,
            new_model: nil,
            mapping: %{},
            renames: %{},
            removed: [],
            added: [],
            capability_changed: [],
            dependencies_changed: [],
            steps: [],
            compensate: false

  @type t :: %__MODULE__{}
end

defmodule AshPPlan.Reactor.Durable.Migration do
  @moduledoc """
  Workflow evolution through subject correspondence, for runs that are parked or pending.

  `plan/3` compares two `AshPPlan.Workflow.Model`s through `AshPPlan.Workflow.Subject`
  correspondence: every task id maps to the same id in the new model, or to the id given in
  `renames: %{old_task => new_task}`; the step name of each is the subject's `:reactor`
  correspondence and the checkpoint key is `Key.for_name/1` of that name. The plan is pure.

  `apply/4` rewrites a stored run: each standing checkpoint of a renamed task is re-recorded
  under the key of its new step (output, impl and args carried over) and the old row is retired
  (`undone_at`), then the record's `model` and `bindings` are replaced, so the renamed step
  REPLAYS its recorded output instead of running again. The migration is written to the run
  `context` under `:migrations` (the ledger entry) and `evidence/1` maps it to
  `AshPPlan.ProcessEvidence` events.

  Refused with typed errors (nothing written):

    * `:run_terminal`, `:run_running` (claimed), `:run_not_migratable` (rolling back or
      blocked), `:no_such_run`, `:subject_mismatch`, `:new_model_unprojectable`,
      `:key_collision`;
    * `:orphaned_checkpoints` with the list of `%{task, label, step_key, cause}` for a standing
      checkpoint whose task was removed (`:task_removed`), whose capability changed
      (`:capability_changed`), whose dependencies changed (`:dependencies_changed`) or whose key
      matches no task of the old model (`:unknown_checkpoint`).

  `compensate: true` (plan or apply option) admits the orphaning change: each orphaned
  checkpoint is claimed, its step's `undo/4` is run from the snapshotted impl and args (a step
  without `undo` is simply taken out of replay), and it is listed under `compensated` in the
  ledger entry; the task then runs again under the new model. A failing undo aborts with
  `:compensation_failed` before the model is switched.

  Apply is idempotent: a run already at the plan's new subject answers `:already_applied`, and
  an apply interrupted midway resumes (a checkpoint standing under its new key is skipped).

  Known limit: a re-recorded checkpoint takes a fresh `seq`, so a rollback (newest first) takes
  renamed steps back before older unrenamed ones. A `Store.rekey/4` callback would preserve it.
  """

  import Kernel, except: [apply: 3]

  alias AshPPlan.ProcessEvidence.Event
  alias AshPPlan.Reactor.Durable.{Clock, Key, Run, Status}
  alias AshPPlan.Reactor.Durable.Migration.Plan
  alias AshPPlan.Workflow.{Model, Subject}

  @migratable ~w(pending waiting polling)a
  @lease_ms 30_000

  # -- plan --------------------------------------------------------------------------------

  @doc """
  Build the correspondence plan from `old` to `new`.

  Options: `:renames` (`%{old_task => new_task}`), `:compensate` (default `false`).
  """
  @spec plan(Model.t(), Model.t(), keyword()) :: {:ok, Plan.t()} | {:error, map()}
  def plan(old, new, opts \\ [])

  def plan(%Model{} = old, %Model{} = new, opts) do
    renames = opts |> Keyword.get(:renames, %{}) |> Map.new()
    old_ids = Enum.map(old.tasks, & &1.id)
    new_ids = Enum.map(new.tasks, & &1.id)

    with :ok <- Model.validate(old),
         :ok <- Model.validate(new),
         :ok <- check_renames(renames, old_ids, new_ids) do
      mapping = build_mapping(old_ids, new_ids, renames)
      targets = Map.values(mapping)

      if length(Enum.uniq(targets)) != length(targets) do
        {:error, %{reason: :ambiguous_rename, targets: targets -- Enum.uniq(targets)}}
      else
        {:ok, assemble(old, new, mapping, renames, Keyword.get(opts, :compensate, false))}
      end
    end
  end

  def plan(old, new, _opts), do: {:error, %{reason: :not_a_model, value: {old, new}}}

  defp check_renames(renames, old_ids, new_ids) do
    bad_from = for {from, _} <- renames, from not in old_ids, do: from
    bad_to = for {_, to} <- renames, to not in new_ids, do: to

    cond do
      bad_from != [] -> {:error, %{reason: :unknown_rename_source, tasks: bad_from}}
      bad_to != [] -> {:error, %{reason: :unknown_rename_target, tasks: bad_to}}
      true -> :ok
    end
  end

  defp build_mapping(old_ids, new_ids, renames) do
    Enum.reduce(old_ids, %{}, fn id, acc ->
      case Map.fetch(renames, id) do
        {:ok, to} -> Map.put(acc, id, to)
        :error -> if id in new_ids, do: Map.put(acc, id, id), else: acc
      end
    end)
  end

  defp assemble(old, new, mapping, renames, compensate) do
    old_tasks = Map.new(old.tasks, &{&1.id, &1})
    new_tasks = Map.new(new.tasks, &{&1.id, &1})

    steps =
      for t <- old.tasks do
        new_id = Map.get(mapping, t.id)
        old_name = step_name(old, t.id)

        %{
          old_task: t.id,
          new_task: new_id,
          old_name: old_name,
          old_key: Key.for_name(old_name),
          old_label: Key.label(old_name),
          new_name: new_id && step_name(new, new_id),
          new_key: new_id && Key.for_name(step_name(new, new_id)),
          new_label: new_id && Key.label(step_name(new, new_id))
        }
      end

    surviving = for {o, n} <- mapping, do: {o, n}

    %Plan{
      old_subject: Subject.bind(old).id,
      new_subject: Subject.bind(new).id,
      old_model: old,
      new_model: new,
      mapping: mapping,
      renames: for({o, n} <- mapping, o != n, into: %{}, do: {o, n}) |> Map.merge(renames),
      removed: for(t <- old.tasks, not Map.has_key?(mapping, t.id), do: t.id),
      added: for(t <- new.tasks, t.id not in Map.values(mapping), do: t.id),
      capability_changed:
        for({o, n} <- surviving, old_tasks[o].capability != new_tasks[n].capability, do: o),
      dependencies_changed:
        for(
          {o, n} <- surviving,
          mapped_deps(old_tasks[o], mapping) != Enum.sort(new_tasks[n].depends_on),
          do: o
        ),
      steps: steps,
      compensate: compensate
    }
  end

  # Old dependencies seen through the correspondence; a removed dependency stays as itself, so it
  # can never equal a new-model id and always counts as a change.
  defp mapped_deps(task, mapping),
    do: task.depends_on |> Enum.map(&Map.get(mapping, &1, {:removed, &1})) |> Enum.sort()

  defp step_name(model, id), do: Subject.correspondence(model.name, id).reactor

  # -- apply -------------------------------------------------------------------------------

  @doc """
  Apply `plan` to the stored run `run_id`.

  Options: `:store_module`, `:bindings` (new task id => realization; default the old bindings
  carried through the correspondence), `:compensate`, `:claimer`.
  """
  @spec apply(term(), String.t(), Plan.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def apply(store, run_id, %Plan{} = plan, opts \\ []) do
    mod = Run.store_module(opts)

    case mod.get_run(store, run_id) do
      nil ->
        {:error, %{reason: :no_such_run, run_id: run_id}}

      record ->
        with :ok <- check_status(record) do
          claim_and_apply(mod, store, record, plan, opts)
        end
    end
  end

  defp check_status(%{status: status} = record) do
    cond do
      Status.terminal?(status) ->
        {:error, %{reason: :run_terminal, status: status, run_id: record.id}}

      status in @migratable ->
        :ok

      true ->
        {:error, %{reason: :run_not_migratable, status: status, run_id: record.id}}
    end
  end

  defp claim_and_apply(mod, store, record, plan, opts) do
    claimer =
      Keyword.get_lazy(opts, :claimer, fn ->
        "migration-" <> Integer.to_string(System.unique_integer([:positive]))
      end)

    case mod.claim(store, record.id, claimer, @lease_ms, Clock.now()) do
      :taken ->
        {:error, %{reason: :run_running, run_id: record.id}}

      {:ok, _} ->
        try do
          fresh = mod.get_run(store, record.id)

          with :ok <- check_status(fresh) do
            do_apply(mod, store, fresh, plan, opts)
          end
        after
          mod.release_claim(store, record.id, claimer)
        end
    end
  end

  defp do_apply(mod, store, record, plan, opts) do
    current = subject_id(record.model)

    cond do
      current == plan.new_subject and current != plan.old_subject ->
        {:ok, %{status: :already_applied, record: record, entry: last_entry(record, plan)}}

      current != plan.old_subject ->
        {:error,
         %{
           reason: :subject_mismatch,
           run: current,
           plan_from: plan.old_subject,
           plan_to: plan.new_subject
         }}

      true ->
        compensate = Keyword.get(opts, :compensate, plan.compensate)
        standing = mod.checkpoints(store, record.id)

        with {:ok, rekey, orphans} <- classify(standing, plan, compensate),
             {:ok, bindings} <- new_bindings(record, plan, opts),
             :ok <- check_collisions(standing, rekey),
             {:ok, compensated} <- compensate_orphans(mod, store, record, orphans) do
          rekeyed = Enum.map(rekey, &rekey!(mod, store, record.id, &1))
          switch(mod, store, record, plan, bindings, rekeyed, compensated)
        end
    end
  end

  defp subject_id(%Model{} = model), do: Subject.bind(model).id
  defp subject_id(_), do: nil

  defp last_entry(record, plan) do
    record.context
    |> Kernel.||(%{})
    |> Map.get(:migrations, [])
    |> Enum.reverse()
    |> Enum.find(&(&1.to == plan.new_subject))
  end

  # Standing checkpoints split into the ones to re-key and the orphans. A checkpoint standing
  # under its new key is already migrated (resume) and is left alone.
  defp classify(checkpoints, plan, compensate) do
    old_by_key = Map.new(plan.steps, &{&1.old_key, &1})
    new_keys = for %{new_key: k} when not is_nil(k) <- plan.steps, into: MapSet.new(), do: k

    {rekey, orphans} =
      checkpoints
      |> Map.values()
      |> Enum.filter(&is_nil(&1.undone_at))
      |> Enum.sort_by(& &1.seq)
      |> Enum.reduce({[], []}, fn cp, {rk, orph} ->
        case Map.fetch(old_by_key, cp.step_key) do
          {:ok, step} ->
            case cause(step, plan) do
              nil -> {if(step.new_key == step.old_key, do: rk, else: rk ++ [{cp, step}]), orph}
              cause -> {rk, orph ++ [orphan(cp, step.old_task, cause)]}
            end

          :error ->
            if MapSet.member?(new_keys, cp.step_key),
              do: {rk, orph},
              else: {rk, orph ++ [orphan(cp, nil, :unknown_checkpoint)]}
        end
      end)

    if orphans != [] and not compensate,
      do: {:error, %{reason: :orphaned_checkpoints, orphaned: orphans}},
      else: {:ok, rekey, orphans}
  end

  defp cause(%{new_task: nil}, _plan), do: :task_removed

  defp cause(%{old_task: task}, plan) do
    cond do
      task in plan.capability_changed -> :capability_changed
      task in plan.dependencies_changed -> :dependencies_changed
      true -> nil
    end
  end

  defp orphan(cp, task, cause),
    do: %{task: task, label: cp.label, step_key: cp.step_key, cause: cause}

  defp new_bindings(record, plan, opts) do
    bindings =
      case Keyword.fetch(opts, :bindings) do
        {:ok, given} ->
          given

        :error ->
          inverse = Map.new(plan.mapping, fn {o, n} -> {n, o} end)
          old = record.bindings || %{}

          for t <- plan.new_model.tasks,
              o = Map.get(inverse, t.id),
              Map.has_key?(old, o),
              into: %{},
              do: {t.id, Map.fetch!(old, o)}
      end

    case Run.reactor_for(%{record | model: plan.new_model, bindings: bindings}) do
      {:ok, _reactor} -> {:ok, bindings}
      {:error, detail} -> {:error, %{reason: :new_model_unprojectable, detail: detail}}
    end
  end

  defp check_collisions(checkpoints, rekey) do
    case for(
           {cp, step} <- rekey,
           Map.has_key?(checkpoints, step.new_key),
           do: {cp.label, step.new_label}
         ) do
      [] -> :ok
      clashes -> {:error, %{reason: :key_collision, collisions: clashes}}
    end
  end

  defp rekey!(mod, store, run_id, {cp, step}) do
    {:ok, _} =
      mod.record(store, run_id, step.new_key, step.new_label, cp.output, %{
        name: step.new_name,
        impl: cp.impl,
        args: cp.args
      })

    _ = mod.claim_undo(store, run_id, cp.step_key, Clock.now())
    %{task: step.old_task, to_task: step.new_task, from: cp.label, to: step.new_label}
  end

  defp compensate_orphans(mod, store, record, orphans) do
    checkpoints = mod.checkpoints(store, record.id)

    Enum.reduce_while(orphans, {:ok, []}, fn orphan, {:ok, done} ->
      cp = Map.fetch!(checkpoints, orphan.step_key)

      case mod.claim_undo(store, record.id, cp.step_key, Clock.now()) do
        :taken ->
          {:cont, {:ok, done}}

        {:ok, claimed} ->
          case undo(claimed, record, mod, store) do
            :ok ->
              {:cont, {:ok, done ++ [orphan.label]}}

            {:error, reason} ->
              mod.release_undo(store, record.id, cp.step_key)

              {:halt,
               {:error, %{reason: :compensation_failed, label: orphan.label, detail: reason}}}
          end
      end
    end)
  end

  defp undo(%{impl: nil}, _record, _mod, _store), do: :ok

  defp undo(cp, record, mod, store) do
    impl = if is_atom(cp.impl), do: {cp.impl, []}, else: cp.impl
    {module, _options} = impl

    if Code.ensure_loaded?(module) do
      step = %Reactor.Step{name: cp.name || cp.label, impl: impl, arguments: []}

      if Reactor.Step.can?(step, :undo) do
        context = %{
          current_step: step,
          durable: %{store: store, store_module: mod, run_id: record.id, checkpoints: %{}}
        }

        case Reactor.Step.undo(step, cp.output, cp.args || %{}, context) do
          :ok -> :ok
          other -> {:error, other}
        end
      else
        :ok
      end
    else
      :ok
    end
  rescue
    e -> {:error, e}
  end

  defp switch(mod, store, record, plan, bindings, rekeyed, compensated) do
    entry = %{
      schema: "ash_pplan/durable-migration/v1",
      from: plan.old_subject,
      to: plan.new_subject,
      renames: plan.renames,
      removed: plan.removed,
      added: plan.added,
      rekeyed: rekeyed,
      compensated: compensated,
      at: Clock.now()
    }

    context = Map.update(record.context || %{}, :migrations, [entry], &(&1 ++ [entry]))
    attrs = %{model: plan.new_model, bindings: bindings, context: context}

    case transition(mod, store, record, attrs) do
      {:ok, updated} -> {:ok, %{status: :migrated, record: updated, entry: entry}}
      {:error, _} = err -> {:error, %{reason: :transition_failed, detail: err}}
    end
  end

  # pending -> pending is not a legal status move; step through waiting and back.
  defp transition(mod, store, %{id: id, status: :pending}, attrs) do
    with {:ok, _} <- mod.transition(store, id, [:pending], :waiting, attrs),
         do: mod.transition(store, id, [:waiting], :pending, %{})
  end

  defp transition(mod, store, %{id: id, status: s}, attrs),
    do: mod.transition(store, id, [s], s, attrs)

  # -- evidence ----------------------------------------------------------------------------

  @doc """
  `AshPPlan.ProcessEvidence` events for every migration recorded in a run's context: one
  `workflow_migrated` event per migration and one `task_rekeyed` / `task_compensated` event per
  step it touched. Feed them to `AshPPlan.ProcessEvidence.export/2`.
  """
  @spec evidence(AshPPlan.Reactor.Durable.Record.t()) :: [Event.t()]
  def evidence(%{id: id, context: context}) do
    run = "run:" <> AshPPlan.ExecutionReceipt.run_identifier(id)

    context
    |> Kernel.||(%{})
    |> Map.get(:migrations, [])
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {m, n} ->
      base = [{"WorkflowRun", run, "run"}, {"Subject", m.to, "subject"}]
      eid = "#{run}/migration/#{n}"

      head = %Event{
        id: eid,
        activity: "workflow_migrated",
        timestamp: m.at,
        objects: base ++ [{"Subject", m.from, "from_subject"}],
        attributes: %{
          from: m.from,
          to: m.to,
          rekeyed: length(m.rekeyed),
          compensated: length(m.compensated)
        },
        subject_id: m.to
      }

      rekeys =
        for r <- m.rekeyed do
          %Event{
            id: "#{eid}/rekey/#{r.from}",
            activity: "task_rekeyed",
            timestamp: m.at,
            objects: base ++ [{"Checkpoint", "cp:" <> r.to, "checkpoint"}],
            attributes: %{from: r.from, to: r.to, task: r.task},
            subject_id: m.to
          }
        end

      comps =
        for label <- m.compensated do
          %Event{
            id: "#{eid}/compensate/#{label}",
            activity: "task_compensated",
            timestamp: m.at,
            objects: base ++ [{"Checkpoint", "cp:" <> label, "checkpoint"}],
            attributes: %{step: label},
            subject_id: m.to
          }
        end

      [head | rekeys ++ comps]
    end)
  end
end
