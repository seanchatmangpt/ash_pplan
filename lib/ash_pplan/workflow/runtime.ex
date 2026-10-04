defmodule AshPPlan.Workflow.Runtime do
  @moduledoc """
  Workflow lifecycle API: plan, resolve, run, observe, resume, explain.

  The runtime owns no scheduler and no executor: Reactor runs the work. It
  composes the projections (`AshPPlan.Workflow.Project.*`), provider
  resolution (`AshPPlan.Providers.Registry`/`Resolver`) and evidence
  (`AshPPlan.Workflow.Evidence`). Nothing here grants DO authority; the
  ceiling is `:construct`.

  A run state is a plain map:

      %{model, subject, registry, bindings, resolutions, outcome, observation,
        evidence, attempt}

  `observe/2` maps a Reactor outcome to a FOND transition
  `{:running, :execute, :succeeded | :failed | :halted}` and, on failure,
  seals the provider that realized the failed step in the registry, so the next
  `run/3` or `resume/3` resolves the next lawful provider (or refuses with a
  typed `:no_qualified_provider` error).

  ## Durable runs

  Without `:store` a run is one in-process Reactor run (DB-free). With `store: store` (a
  `AshPPlan.Reactor.Durable.Store` handle, e.g. `Store.Ets.start_link/1`) the run is a row in
  the ledger: `run/3` starts it with `Engine.start/3` and makes one `Engine.attempt/3`;
  a wait parks it (`observation.state == :halted`); `resume/2` delivers an optional
  `signal: {name, payload}` and attempts again (replaying recorded steps); `signal/3` delivers a
  signal without attempting. A failed durable run is terminal; `resume/2` is then an explicit
  failover that re-resolves only the failed task against the sealed registry and starts a new
  run (`<run_id>-a<attempt>`) over the merged bindings.
  """

  import Kernel, except: [inspect: 1]

  alias AshPPlan.{ReactorOutcome, Capability}
  alias AshPPlan.Providers.Registry
  alias AshPPlan.Reactor.Durable.Engine
  alias AshPPlan.Workflow.{Authority, Evidence, Explain, Model, Subject}
  alias AshPPlan.Workflow.Project.Reactor, as: ProjectReactor

  @kinds [:pplan, :hddl, :fond, :reactor]

  @doc "Normalize a model, a generated workflow module, or a keyword/map description."
  @spec model(Model.t() | module() | keyword() | map()) :: {:ok, Model.t()} | {:error, map()}
  def model(%Model{} = m), do: {:ok, m}

  def model(mod) when is_atom(mod) and not is_nil(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :model, 0) do
      model(mod.model())
    else
      {:error, %{reason: :unknown_workflow, module: mod}}
    end
  end

  def model(attrs) when is_list(attrs) or is_map(attrs), do: Model.new(attrs)
  def model(other), do: {:error, %{reason: :not_a_model, value: other}}

  @doc "Validate a workflow: structure, authority ceiling, subject binding."
  @spec validate(term()) :: {:ok, map()} | {:error, map()}
  def validate(source) do
    with {:ok, m} <- model(source),
         :ok <- Model.validate(m),
         {:ok, ceiling} <- Authority.admit(m) do
      {:ok, %{subject: Subject.bind(m), ceiling: ceiling, granted: Authority.granted(m)}}
    end
  end

  @doc "Validate then project a workflow to its P-PLAN plan; grants no authority."
  @spec plan(term(), keyword()) :: {:ok, map()} | {:error, map()}
  def plan(source, _opts \\ []) do
    with {:ok, m} <- model(source),
         {:ok, v} <- validate(m),
         {:ok, plan} <- project(m, :pplan) do
      {:ok, %{model: m, subject: v.subject, ceiling: v.ceiling, plan: plan}}
    end
  end

  @doc "Project to `:pplan | :hddl | :fond | :reactor` (reactor needs `:bindings`)."
  @spec project(term(), atom(), keyword()) :: {:ok, term()} | {:error, map()}
  def project(source, kind, opts \\ [])

  def project(source, kind, opts) when kind in @kinds do
    with {:ok, m} <- model(source) do
      case kind do
        :pplan ->
          wrap(dispatch(Module.concat(project_ns(), PPlan), :project, [m]))

        :hddl ->
          wrap(dispatch(Module.concat(project_ns(), HDDL), :render, [m]))

        :fond ->
          dispatch(Module.concat(project_ns(), FOND), :project, [m])

        :reactor ->
          dispatch(Module.concat(project_ns(), Reactor), :project, [
            m,
            Keyword.get(opts, :bindings, %{}),
            Keyword.take(opts, [:adapters])
          ])
      end
    end
  end

  def project(_source, kind, _opts), do: {:error, %{reason: :unknown_projection, kind: kind}}

  defp project_ns, do: AshPPlan.Workflow.Project
  defp wrap({:ok, _} = ok), do: ok
  defp wrap({:error, _} = err), do: err
  defp wrap(value), do: {:ok, value}

  defp dispatch(mod, fun, args) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    else
      {:error, %{reason: :projection_unavailable, module: mod, function: fun}}
    end
  end

  @doc "Generated capability catalog when present, else the capability families."
  @spec capabilities() :: [term()]
  def capabilities do
    cat = AshPPlan.Workflow.CapabilityCatalog

    if Code.ensure_loaded?(cat) and function_exported?(cat, :all, 0),
      do: apply(cat, :all, []),
      else: Capability.families()
  end

  @doc "Provider modules: the generated provider index."
  @spec providers() :: [module()]
  def providers, do: Registry.providers(Registry.default())

  @doc "Registry from `:registry` (struct), `:providers` (modules), or defaults."
  @spec registry(keyword()) :: Registry.t()
  def registry(opts) do
    case {Keyword.get(opts, :registry), Keyword.get(opts, :providers)} do
      {%Registry{} = r, _} -> r
      {_, mods} when is_list(mods) -> Registry.new(mods)
      _ -> Registry.new(providers())
    end
  end

  @doc """
  Resolve a provider for every task. Returns bindings
  `%{task_id => %AshPPlan.Realization{}}` usable by the Reactor projection,
  or a typed refusal naming the unresolved task.
  """
  @spec resolve(term(), keyword()) :: {:ok, map()} | {:error, map()}
  def resolve(source, opts \\ []) do
    with {:ok, m} <- model(source),
         {:ok, order} <- Model.topological_order(m) do
      reg = registry(opts)
      ctx = %{ceiling: Keyword.get(opts, :ceiling, :construct)}
      by_id = Map.new(m.tasks, &{&1.id, &1})

      order
      |> Enum.reduce_while({:ok, %{}, %{}}, fn id, {:ok, binds, res} ->
        task = Map.fetch!(by_id, id)

        case Registry.resolve(reg, requirement(task), ctx) do
          {:ok, r} ->
            {:cont, {:ok, Map.put(binds, id, r.realization), Map.put(res, id, r)}}

          {:error, detail} ->
            {:halt, {:error, %{reason: :no_qualified_provider, task: id, detail: detail}}}
        end
      end)
      |> case do
        {:ok, binds, res} -> {:ok, %{bindings: binds, resolutions: res, registry: reg}}
        error -> error
      end
    end
  end

  defp requirement(task) do
    %{
      capability: task.capability,
      properties: Enum.map(task.properties, &atomize/1),
      evidence: Enum.map(task.evidence, &atomize/1),
      authority: resolver_authority(task.authority),
      options: []
    }
  end

  defp resolver_authority(a) when a in [:select, :plan], do: :observe
  defp resolver_authority(a), do: a

  defp atomize(v) when is_binary(v) do
    String.to_existing_atom(v)
  rescue
    ArgumentError -> v
  end

  defp atomize(v), do: v

  @doc """
  Plan, resolve and run through Reactor. Returns `{:ok, run_state}` once
  execution was attempted (inspect `run_state.observation`), or a typed refusal
  when nothing could be planned/resolved/projected.
  """
  @spec run(term(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def run(source, inputs \\ %{}, opts \\ []) do
    with {:ok, p} <- plan(source),
         {:ok, r} <- resolve(p.model, opts),
         {:ok, reactor} <-
           project(p.model, :reactor, [bindings: r.bindings] ++ Keyword.take(opts, [:adapters])) do
      state = %{
        model: p.model,
        subject: p.subject,
        registry: r.registry,
        bindings: r.bindings,
        resolutions: r.resolutions,
        attempt: Keyword.get(opts, :attempt, 1)
      }

      case Keyword.get(opts, :store) do
        nil -> execute(state, reactor, inputs, opts)
        store -> start_durable(state, store, inputs, opts)
      end
    end
  end

  # ---- durable path: thin over Durable.Engine ----

  defp start_durable(state, store, inputs, opts) do
    run_id =
      Keyword.get_lazy(opts, :run_id, fn -> "wf-run-#{System.unique_integer([:positive])}" end)

    attrs = %{
      id: run_id,
      model: state.model,
      bindings: state.bindings,
      inputs: wrap_input(inputs),
      context: opts |> Keyword.get(:context, %{}) |> Map.put(:run_id, run_id),
      parent: Keyword.get(opts, :parent)
    }

    {:ok, _record} = Engine.start(store, attrs, engine_opts(opts))

    state
    |> Map.merge(%{store: store, run_id: run_id, inputs: inputs})
    |> attempt_durable(opts)
  end

  defp attempt_durable(%{store: store, run_id: run_id} = state, opts) do
    started_at = DateTime.utc_now()
    started_mono = System.monotonic_time(:microsecond)
    eopts = engine_opts(opts)

    outcome = store |> Engine.attempt(run_id, eopts) |> durable_outcome(store, run_id, eopts)

    observe(Map.put(state, :outcome, outcome), outcome,
      started_at: started_at,
      started_mono: started_mono
    )
  end

  defp engine_opts(opts), do: Keyword.take(opts, [:store_module, :lease_ms, :halt_timeout])

  # Map an engine outcome onto the Reactor result shapes `ReactorOutcome` classifies.
  defp durable_outcome({:completed, result}, _store, _id, _o), do: {:ok, result}

  defp durable_outcome({:parked, status}, store, id, o) do
    done = store |> Engine.steps(id, o) |> Map.new(&{&1.label, &1.output})

    {:halted,
     %{
       durable: true,
       run_id: id,
       status: status,
       store: store,
       state: status,
       intermediate_results: done
     }}
  end

  defp durable_outcome({:failed, error}, _store, _id, _o), do: {:error, error}
  defp durable_outcome({:rolled_back, status}, _s, _id, _o), do: {:error, {:rolled_back, status}}
  defp durable_outcome(:taken, _store, _id, _o), do: {:error, :run_taken}
  defp durable_outcome(:not_found, _store, _id, _o), do: {:error, :run_not_found}

  defp durable_outcome(:ended, store, id, eopts) do
    case Engine.fetch(store, id, eopts) do
      %{status: :completed, result: result} -> {:ok, result}
      %{status: :failed, error: error} -> {:error, error}
      %{status: status} -> {:error, {:rolled_back, status}}
    end
  end

  @doc """
  Deliver a signal to a durable run state (`store` and `run_id` in the state). Does not attempt.
  """
  @spec signal(map(), String.t(), term(), keyword()) :: {:ok, term()} | {:error, map()}
  def signal(state, name, payload, opts \\ [])

  def signal(%{store: store, run_id: run_id}, name, payload, opts),
    do: Engine.signal(store, run_id, name, payload, engine_opts(opts))

  def signal(_state, _name, _payload, _opts), do: {:error, %{reason: :not_a_durable_run}}

  @doc """
  Cancel a durable run state parked on a wait, then attempt once so the engine unwinds recorded
  steps (`{:rolled_back, :cancelled}`). Returns the observed run state; a run that is not
  cancellable (terminal) is a typed refusal. Nothing is sealed: a cancellation is not a
  provider failure.
  """
  @spec cancel(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def cancel(state, opts \\ [])

  def cancel(%{store: store, run_id: run_id} = state, opts) do
    case Engine.cancel(store, run_id, engine_opts(opts)) do
      {:ok, _record} -> attempt_durable(state, opts)
      {:error, reason} -> {:error, %{reason: reason, run_id: run_id}}
    end
  end

  def cancel(_state, _opts), do: {:error, %{reason: :not_a_durable_run}}

  defp execute(state, reactor, inputs, opts) do
    run_id =
      Keyword.get_lazy(opts, :run_id, fn -> "wf-run-#{System.unique_integer([:positive])}" end)

    context = opts |> Keyword.get(:context, %{}) |> Map.put(:run_id, run_id)
    started_at = DateTime.utc_now()
    started_mono = System.monotonic_time(:microsecond)

    outcome = Reactor.run(reactor, wrap_input(inputs), context, run_id: run_id)

    observe(
      Map.merge(state, %{outcome: outcome, run_id: run_id, inputs: inputs, reactor: reactor}),
      outcome,
      started_at: started_at,
      started_mono: started_mono
    )
  end

  defp wrap_input(%{input: _} = inputs), do: inputs
  defp wrap_input(inputs), do: %{input: inputs}

  @doc """
  Observe a Reactor outcome: FOND transition, bound evidence and, on failure,
  provider sealing. Options: `:failed_task` (otherwise derived from the error).

  Evidence binding failures (e.g. `{:error, %{reason: :invalid_literal, field,
  value}}` from `Evidence.bind/2`) are returned typed with the run id attached
  instead of raising — an observation failure is never a bare raise that
  unseals the durable run (ZD2 court 2026-10-04).
  """
  @spec observe(map(), term(), keyword()) :: {:ok, map()} | {:error, map()}
  def observe(state, outcome, opts \\ []) do
    obs = ReactorOutcome.observe(outcome)
    to = obs.state

    case Evidence.bind(state.model, evidence_opts(state, outcome, opts)) do
      {:ok, ev} ->
        {registry, sealed, failed_task} =
          case to do
            :failed -> seal_failed(state, obs, opts)
            _ -> {state.registry, nil, nil}
          end

        {:ok,
         Map.merge(state, %{
           outcome: outcome,
           registry: registry,
           observation: %{
             transition: %{from: :running, action: :execute, to: to},
             state: to,
             sealed: sealed,
             failed_task: failed_task,
             detail: Map.drop(obs, [:state, :reactor])
           },
           evidence: ev
         })}

      {:error, reason} ->
        {:error, Map.put(reason, :run_id, Map.get(state, :run_id))}
    end
  end

  defp evidence_opts(state, outcome, opts) do
    [outcome: outcome]
    |> put_if(:run_id, Map.get(state, :run_id))
    |> put_if(:started_at, opts[:started_at])
    |> put_if(:started_mono, opts[:started_mono])
    |> put_if(:corresponds_to_steps, step_iris(state))
  end

  # p-plan:correspondsToStep source: the model is in scope here, so the step
  # IRIs are the same `Project.Reactor.step_iri/2` values the reactor
  # projection bound the realizations to. No model -> no claim (honest absence).
  defp step_iris(%{model: %Model{} = model}),
    do: Enum.map(model.tasks, &ProjectReactor.step_iri(model, &1.id))

  defp step_iris(_), do: nil

  defp put_if(kw, _k, nil), do: kw
  defp put_if(kw, k, v), do: Keyword.put(kw, k, v)

  defp seal_failed(state, obs, opts) do
    task = Keyword.get(opts, :failed_task) || failed_step(obs.reason, Map.keys(state.bindings))

    with task when not is_nil(task) <- task,
         %{provider: mod} <- Map.get(state.resolutions, task) do
      {Registry.seal(state.registry, mod, {:failed, task}), mod, task}
    else
      _ -> {state.registry, nil, task}
    end
  end

  # Find the failed task id by walking the Reactor error for a step name.
  defp failed_step(reason, ids) do
    names = reason |> collect_names([]) |> Enum.reverse()

    Enum.find_value(names, fn n -> Enum.find(ids, &step_matches?(n, &1)) end)
  end

  defp step_matches?(name, id) do
    name = to_string(name)
    name == to_string(id) or String.ends_with?(name, "#step-" <> to_string(id))
  end

  defp collect_names(%{__struct__: _} = s, acc) do
    acc = if is_map_key(s, :name) and not is_map_key(s, :errors), do: [s.name | acc], else: acc
    s |> Map.from_struct() |> Map.values() |> Enum.reduce(acc, &collect_names/2)
  end

  defp collect_names(l, acc) when is_list(l), do: Enum.reduce(l, acc, &collect_names/2)
  defp collect_names(t, acc) when is_tuple(t), do: t |> Tuple.to_list() |> collect_names(acc)
  defp collect_names(_, acc), do: acc

  @doc """
  Resume a run state. A halted reactor is resumed in place; a failed run is
  re-resolved against the (sealed) registry and re-run, so an alternative
  provider is chosen or a typed refusal is returned.
  """
  @spec resume(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def resume(state, opts \\ [])

  def resume(%{store: store, run_id: run_id, observation: %{state: :halted}} = state, opts) do
    case Keyword.get(opts, :signal) do
      {name, payload} -> {:ok, _} = Engine.signal(store, run_id, name, payload, engine_opts(opts))
      _ -> :ok
    end

    attempt_durable(state, opts)
  end

  def resume(%{store: store, observation: %{state: :failed}} = state, opts) do
    failover(state, store, opts)
  end

  def resume(%{observation: %{state: :halted}, outcome: {:halted, reactor}} = state, opts) do
    execute(state, reactor, %{}, opts)
  end

  def resume(%{observation: %{state: :failed}} = state, opts) do
    run(
      state.model,
      Map.get(state, :inputs, %{}),
      opts |> Keyword.put(:registry, state.registry) |> Keyword.put(:attempt, state.attempt + 1)
    )
  end

  def resume(state, _opts),
    do: {:error, %{reason: :not_resumable, state: get_in(state, [:observation, :state])}}

  # Explicit failover: only the failed task is re-resolved against the sealed registry; every
  # other binding is kept. The failed run is terminal, so the merged bindings start a new run.
  defp failover(state, store, opts) do
    task = state.observation.failed_task
    by_id = Map.new(state.model.tasks, &{&1.id, &1})

    with task when not is_nil(task) <- task,
         %{} = t <- Map.get(by_id, task),
         {:ok, r} <-
           failover_resolve(state.registry, t, Keyword.get(opts, :ceiling, :construct)) do
      attempt = state.attempt + 1

      next =
        Map.merge(state, %{
          bindings: Map.put(state.bindings, task, r.realization),
          resolutions: Map.put(state.resolutions, task, r),
          attempt: attempt
        })

      opts =
        opts |> Keyword.delete(:run_id) |> Keyword.put(:run_id, "#{state.run_id}-a#{attempt}")

      start_durable(next, store, Map.get(state, :inputs, %{}), opts)
    else
      {:error, detail} ->
        {:error,
         %{reason: :no_qualified_provider, task: state.observation.failed_task, detail: detail}}

      _ ->
        {:error, %{reason: :not_resumable, state: :failed, detail: :unknown_failed_task}}
    end
  end

  defp failover_resolve(registry, task, ceiling),
    do: Registry.resolve(registry, requirement(task), %{ceiling: ceiling})

  @doc "Compact structural view of a workflow."
  @spec inspect(term()) :: {:ok, map()} | {:error, map()}
  def inspect(source) do
    with {:ok, v} <- validate(source),
         {:ok, m} <- model(source),
         {:ok, order} <- Model.topological_order(m) do
      {:ok,
       %{
         name: m.name,
         goal: m.goal,
         subject: v.subject.id,
         ceiling: v.ceiling,
         order: order,
         tasks:
           Map.new(
             m.tasks,
             &{&1.id, %{capability: &1.capability, after: &1.depends_on, authority: &1.authority}}
           ),
         methods: Enum.map(m.methods, & &1.id),
         evidence: Evidence.profile(m)
       }}
    end
  end

  @doc "Answer the PRD section 37 questions for a workflow or a run state."
  @spec explain(term(), keyword()) :: {:ok, map()} | {:error, map()}
  def explain(%{model: _, observation: _} = state, _opts), do: {:ok, Explain.run(state)}

  def explain(source, opts) do
    with {:ok, m} <- model(source) do
      resolved =
        case resolve(m, opts) do
          {:ok, r} -> r
          {:error, e} -> %{error: e}
        end

      {:ok, Explain.workflow(m, resolved)}
    end
  end

  def explain(source), do: explain(source, [])
end
