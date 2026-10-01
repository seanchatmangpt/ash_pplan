defmodule AshPPlan.Reactor do
  @moduledoc """
  Binds a Reactor to one workflow subject so semantic identity survives
  execution, dynamic expansion and durable resumption.

  `enrich/3` stamps every step with its semantic identity (workflow, task,
  IRI, capability, properties, authority ceiling) under the step context key
  `:ash_pplan_workflow`, sets the reactor id to the subject-bound plan IRI
  (the identity the durable ledger replays against) and installs
  `AshPPlan.Reactor.Middleware.Identity` and
  `AshPPlan.Reactor.Middleware.Evidence`. Step contexts live inside the
  Reactor struct, so a parked and replayed Reactor carries them across a
  `AshPPlan.Reactor.Durable.Engine` attempt boundary unchanged.

  `inherit/2` gives steps created at run time (dynamic expansion) a child
  identity derived from the parent step. A child can never exceed its parent's
  authority ceiling, and nothing here grants `:do`: the ceiling is
  `:construct`.
  """

  alias AshPPlan.Workflow.{Model, Subject}

  @key :ash_pplan_workflow
  @authorities Model.authorities()

  @adapters %{
    reactor_file: AshPPlan.Reactor.Adapters.ReactorFile,
    reactor_req: AshPPlan.Reactor.Adapters.ReactorReq,
    reactor_process: AshPPlan.Reactor.Adapters.ReactorProcess,
    ash_reactor: AshPPlan.Reactor.Adapters.AshReactor,
    bb_reactor: AshPPlan.Reactor.Adapters.BbReactor,
    local: AshPPlan.Reactor.Adapters.Local,
    durable: AshPPlan.Reactor.Adapters.Durable
  }

  @doc """
  Adapter id to adapter module table: the built-ins merged with
  `Application.get_env(:ash_pplan, :extra_adapters, %{})`.
  """
  @spec adapters() :: %{atom() => module()}
  def adapters do
    Map.merge(@adapters, Map.new(Application.get_env(:ash_pplan, :extra_adapters, %{})))
  end

  @doc """
  Resolve a realization to `{step_module, step_options}`. The only place a
  realization becomes a Reactor implementation. Options: `:adapters` (override
  table), `:available?` (forwarded to the adapter). The resolved module must
  implement `Reactor.Step`, otherwise `{:error, %{reason: :not_a_step, ...}}`.
  """
  @spec step_for(AshPPlan.Realization.t(), keyword()) ::
          {:ok, {module(), keyword()}} | {:error, map()}
  def step_for(realization, opts \\ [])

  def step_for(%AshPPlan.Realization{binding: %{adapter: adapter, op: op}} = r, opts) do
    table = Keyword.get(opts, :adapters) || adapters()
    extra = if Keyword.has_key?(opts, :available?), do: [available?: opts[:available?]], else: []

    case Map.fetch(table, adapter) do
      {:ok, mod} ->
        with {:ok, {step, kw}} <- mod.step(op, Keyword.merge(r.options, extra)),
             :ok <- validate_step(step) do
          {:ok, {step, kw}}
        end

      :error ->
        {:error, %{reason: :unsupported, adapter: adapter, detail: :unknown_adapter}}
    end
  end

  def step_for(%AshPPlan.Realization{binding: binding}, _opts),
    do: {:error, %{reason: :unsupported, adapter: nil, detail: {:invalid_binding, binding}}}

  @doc "Check that `module` is a loaded `Reactor.Step` implementation."
  @spec validate_step(term()) :: :ok | {:error, map()}
  def validate_step(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :run, 3) and
         Reactor.Step in Keyword.get(module.module_info(:attributes), :behaviour, []) do
      :ok
    else
      {:error, %{reason: :not_a_step, module: module}}
    end
  end

  def validate_step(other), do: {:error, %{reason: :not_a_step, module: other}}

  @doc "Step and run context key carrying workflow identity."
  @spec context_key() :: atom()
  def context_key, do: @key

  @doc """
  Enrich `reactor` with the identity of `model`.

  Options: `:verify` (default `true`) checks, through
  `AshPPlan.Workflow.Subject.verify_projection/3`, that the reactor carries
  exactly the model's tasks.
  """
  @spec enrich(Reactor.t(), Model.t(), keyword()) :: {:ok, Reactor.t()} | {:error, map()}
  def enrich(reactor, model, opts \\ [])

  def enrich(%Reactor{} = reactor, %Model{} = model, opts) do
    with :ok <- Model.validate(model),
         :ok <- verify(model, reactor, Keyword.get(opts, :verify, true)) do
      subject = Subject.bind(model)

      by_task =
        Map.new(model.tasks, &{Map.fetch!(subject.correspondence, &1.id).reactor, &1})

      steps =
        Enum.map(reactor.steps, fn step ->
          step = portable_ref(step)

          case Map.fetch(by_task, to_string(step.name)) do
            {:ok, task} ->
              %{step | context: Map.put(step.context, @key, identity(model, subject, task))}

            :error ->
              step
          end
        end)

      run_identity = %{subject: subject.id, workflow: model.name}

      plan_iri = AshPPlan.Workflow.Evidence.plan_iri(subject.id)

      reactor = %{
        reactor
        | id: plan_iri,
          steps: steps,
          context:
            reactor.context
            |> Map.put(@key, run_identity)
            |> rebind_composed(reactor.id, plan_iri)
      }

      add_middleware(reactor, [
        AshPPlan.Reactor.Middleware.Identity,
        AshPPlan.Reactor.Middleware.Evidence
      ])
    end
  end

  def enrich(%Reactor{}, other, _opts), do: {:error, %{reason: :not_a_model, value: other}}
  def enrich(other, _model, _opts), do: {:error, %{reason: :not_a_reactor, value: other}}

  @doc "The identity stamped on a step (or a step context), or `nil`."
  @spec identity_of(Reactor.Step.t() | map()) :: map() | nil
  def identity_of(%Reactor.Step{context: context}), do: identity_of(context)
  def identity_of(%{@key => %{task: _} = identity}), do: identity
  def identity_of(_), do: nil

  @doc """
  Give dynamically created `steps` a child identity of `parent`.

  `parent` is a `Reactor.Step`, a step/run context map carrying
  `:ash_pplan_workflow`, or the identity map itself. A child inherits the
  subject, workflow, capability, properties and the parent's authority
  ceiling; its task id is `"<parent task>/<step name>"`. A child that asks (via
  its own `:ash_pplan_workflow` context, key `:authority`) for authority above
  the parent's ceiling, or an authority outside the model's vocabulary, is
  refused.
  """
  @spec inherit(Reactor.Step.t() | map(), Reactor.Step.t() | [Reactor.Step.t()]) ::
          {:ok, Reactor.Step.t() | [Reactor.Step.t()]} | {:error, map()}
  def inherit(parent, steps) when is_list(steps) do
    with {:ok, identity} <- parent_identity(parent) do
      steps
      |> Enum.reduce_while({:ok, []}, fn step, {:ok, acc} ->
        case inherit_one(identity, step) do
          {:ok, s} -> {:cont, {:ok, [s | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        err -> err
      end
    end
  end

  def inherit(parent, %Reactor.Step{} = step) do
    with {:ok, identity} <- parent_identity(parent), do: inherit_one(identity, step)
  end

  def inherit(_parent, other), do: {:error, %{reason: :not_a_step, value: other}}

  @doc "Install middlewares on a reactor, idempotently."
  @spec add_middleware(Reactor.t(), [module()]) :: {:ok, Reactor.t()} | {:error, map()}
  def add_middleware(%Reactor{} = reactor, middlewares) do
    Enum.reduce_while(middlewares, {:ok, reactor}, fn mw, {:ok, r} ->
      if installed?(r, mw) do
        {:cont, {:ok, r}}
      else
        case Reactor.Builder.add_middleware(r, mw) do
          {:ok, r} -> {:cont, {:ok, r}}
          {:error, reason} -> {:halt, {:error, %{reason: :middleware_refused, error: reason}}}
        end
      end
    end)
  end

  defp installed?(%Reactor{middleware: middleware}, mw) do
    Enum.any?(middleware, fn
      %{__struct__: _} = m -> m.__struct__ == mw or Map.get(m, :module) == mw
      m -> m == mw
    end)
  end

  # Reactor's default step ref is `make_ref/0`, a runtime-only identity that no
  # durable codec can carry. The step name is the semantic, portable ref.
  defp portable_ref(%Reactor.Step{ref: ref} = step) when is_reference(ref),
    do: %{step | ref: step.name}

  defp portable_ref(step), do: step

  # `Reactor.Builder.new/1` records the reactor's own id in
  # `private.composed_reactors`; with a `make_ref/0` id that is a runtime-only
  # term, so it follows the id to the portable plan IRI.
  defp rebind_composed(%{private: %{composed_reactors: composed} = private} = context, old, new) do
    composed = composed |> MapSet.delete(old) |> MapSet.put(new)
    %{context | private: %{private | composed_reactors: composed}}
  end

  defp rebind_composed(context, _old, _new), do: context

  defp verify(_model, _reactor, false), do: :ok
  defp verify(model, reactor, _), do: Subject.verify_projection(model, :reactor, reactor)

  defp identity(model, subject, task) do
    corr = Map.fetch!(subject.correspondence, task.id)

    %{
      subject: subject.id,
      workflow: model.name,
      task: to_string(task.id),
      iri: corr.semantic,
      capability: cap_string(task.capability),
      properties: Enum.map(task.properties, &to_string/1),
      authority: task.authority,
      parent: nil
    }
  end

  defp cap_string(nil), do: nil
  defp cap_string(cap) when is_binary(cap), do: cap
  defp cap_string(cap) when is_atom(cap), do: Atom.to_string(cap)
  defp cap_string(cap), do: inspect(cap)

  defp parent_identity(%Reactor.Step{context: context}), do: parent_identity(context)

  defp parent_identity(%{@key => %{task: _} = identity}), do: {:ok, identity}
  defp parent_identity(%{task: _, subject: _} = identity), do: {:ok, identity}
  defp parent_identity(_), do: {:error, %{reason: :parent_without_identity}}

  defp inherit_one(parent, %Reactor.Step{} = step) do
    requested = requested_authority(step, parent.authority)

    cond do
      requested not in @authorities ->
        {:error,
         %{reason: :unknown_authority, authority: requested, task: child_task(parent, step)}}

      rank(requested) > rank(parent.authority) ->
        {:error,
         %{
           reason: :authority_escalation,
           task: child_task(parent, step),
           ceiling: parent.authority,
           requested: requested
         }}

      true ->
        task = child_task(parent, step)

        identity = %{
          parent
          | task: task,
            iri: parent.iri <> "/" <> to_string(step.name),
            authority: requested,
            parent: parent.task
        }

        {:ok, %{step | context: Map.put(step.context, @key, identity)}}
    end
  end

  defp inherit_one(_parent, other), do: {:error, %{reason: :not_a_step, value: other}}

  defp requested_authority(%Reactor.Step{context: context}, default) do
    case context do
      %{@key => %{authority: authority}} -> authority
      _ -> default
    end
  end

  defp child_task(parent, step), do: parent.task <> "/" <> to_string(step.name)
  defp rank(authority), do: Enum.find_index(@authorities, &(&1 == authority)) || -1
end
