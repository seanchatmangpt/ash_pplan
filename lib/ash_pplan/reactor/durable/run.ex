defmodule AshPPlan.Reactor.Durable.Run do
  @moduledoc """
  Turns a stored run into a durable Reactor and runs it.

  `reactor_for/1` rebuilds the reactor from the record's `model` + `bindings` exactly as
  `AshPPlan.Workflow.Runtime` projects it (so step names are deterministic across attempts);
  `decorate/2` wraps every step in `AshPPlan.Reactor.Durable.Checkpointed`, prepends the durable
  middleware and merges the durable context. Reactor's planner and executor are untouched.

  Every step sees `context.durable = %{store:, store_module:, run_id:, checkpoints:}` where
  `checkpoints` is `%{step_key => output}` loaded once per attempt.

  Design derived from mbuhot/magma (MIT per its mix.exs), re-implemented.
  """

  alias AshPPlan.Reactor.Durable.{Checkpointed, Key, Middleware, Record, Verifier}
  alias AshPPlan.Workflow.Project

  @default_store_module AshPPlan.Reactor.Durable.Store.Ets
  @default_halt_timeout 5_000

  @doc "Store implementation module for `opts` (`:store_module`, app env, or the ETS store)."
  @spec store_module(keyword()) :: module()
  def store_module(opts \\ []) do
    Keyword.get(opts, :store_module) ||
      Application.get_env(:ash_pplan, :durable_store_module) || @default_store_module
  end

  @doc "Rebuild the (undecorated, identity-enriched) reactor of a run record."
  @spec reactor_for(Record.t()) :: {:ok, Reactor.t()} | {:error, term()}
  def reactor_for(%Record{model: model, bindings: bindings}) do
    with {:ok, reactor} <- Project.Reactor.project(model, bindings || %{}) do
      AshPPlan.Reactor.enrich(reactor, model)
    end
  end

  @doc """
  Run a record's reactor, replaying whatever it has already recorded.

  Options: `:store_module`, `:halt_timeout`, `:max_concurrency`.
  """
  @spec run(term(), Record.t(), keyword()) :: {:ok, term()} | {:halted, term()} | {:error, term()}
  def run(store, %Record{} = record, opts \\ []) do
    mod = store_module(opts)

    with {:ok, reactor} <- reactor_for(record),
         :ok <- Verifier.verify(reactor) do
      durable = %{
        store: store,
        store_module: mod,
        run_id: record.id,
        checkpoints: load_checkpoints(mod, store, record.id)
      }

      reactor = decorate(reactor, durable)

      run_opts = [
        max_concurrency: Keyword.get(opts, :max_concurrency) || concurrency(reactor),
        halt_timeout:
          Keyword.get(opts, :halt_timeout) ||
            Application.get_env(:ash_pplan, :durable_halt_timeout, @default_halt_timeout)
      ]

      Reactor.run(reactor, wrap_input(record.inputs), record.context || %{}, run_opts)
    end
  end

  defp wrap_input(%{input: _} = inputs), do: inputs
  defp wrap_input(nil), do: %{input: %{}}
  defp wrap_input(inputs), do: %{input: inputs}

  defp load_checkpoints(mod, store, run_id) do
    store
    |> mod.checkpoints(run_id)
    |> Enum.reject(fn {_k, cp} -> cp.undone_at != nil end)
    |> Map.new(fn {k, cp} -> {k, cp.output} end)
  end

  # Every wait a run could park on at once needs a slot of its own: Reactor stops at the first
  # halt, so a wait left out of that batch never records what it waits for.
  defp concurrency(reactor),
    do: System.schedulers_online() + Enum.count(reactor.steps, &waits?/1)

  defp waits?(%Reactor.Step{impl: {Checkpointed, options}}) do
    case Keyword.get(options, :durable_inner) do
      {AshPPlan.Reactor.Durable.Steps.Await, _} -> true
      {AshPPlan.Reactor.Durable.Steps.Poll, _} -> true
      AshPPlan.Reactor.Durable.Steps.Await -> true
      AshPPlan.Reactor.Durable.Steps.Poll -> true
      _ -> false
    end
  end

  defp waits?(_), do: false

  @doc "Wrap every step, neutralise guards, prepend the middleware and merge the durable context."
  @spec decorate(Reactor.t(), map()) :: Reactor.t()
  def decorate(%Reactor{} = reactor, durable) do
    %{
      reactor
      | middleware: [Middleware | Enum.reject(reactor.middleware, &(&1 == Middleware))],
        context: Map.put(reactor.context, :durable, durable),
        steps: Enum.map(reactor.steps, &decorate_step(&1, %{durable: durable}))
    }
  end

  @doc "Wrap one step; also used for steps a composite returns at run time."
  @spec decorate_step(Reactor.Step.t(), map()) :: Reactor.Step.t()
  def decorate_step(%Reactor.Step{impl: {Checkpointed, _}} = step, _context), do: step

  # The run half of a compose records a live %Reactor{}: nothing stored of it could replay into a
  # working undo, so it stays undecorated and its nested reactor re-runs.
  def decorate_step(%Reactor.Step{name: {:compose, _}} = step, _context), do: step

  def decorate_step(%Reactor.Step{} = step, _context) do
    %{
      step
      | impl: {Checkpointed, durable_inner: step.impl, durable_name: step.name},
        guards: Enum.map(step.guards, &neutralise(&1, step.name))
    }
  end

  # A recorded step keeps the answer its guards gave the first time.
  defp neutralise(%Reactor.Guard{} = guard, name) do
    original = guard.fun

    %{
      guard
      | fun: fn arguments, context ->
          case recorded(context, name) do
            {:ok, _} -> :cont
            :miss -> apply_guard(original, arguments, context)
          end
        end
    }
  end

  defp apply_guard({m, f, a}, arguments, context), do: apply(m, f, [arguments, context | a])
  defp apply_guard(fun, arguments, context) when is_function(fun, 2), do: fun.(arguments, context)

  @doc "Raise unless the running step is one of the outer plan's own (not inside a nesting composite)."
  @spec assert_own_step!(map(), String.t()) :: :ok
  def assert_own_step!(context, entity) do
    own = Map.get(context, :durable_step)
    current = Map.get(context, :current_step)

    if own === current do
      :ok
    else
      raise "#{entity} #{Key.label(current.name)} sits inside a nesting composite that runs " <>
              "its steps in a private reactor; it holds no checkpoint and cannot halt to wait."
    end
  end

  @doc "What a step recorded on an earlier attempt, if anything."
  @spec recorded(map(), term()) :: {:ok, term()} | :miss
  def recorded(%{durable: %{checkpoints: checkpoints}}, name) do
    case Map.fetch(checkpoints, Key.for_name(name)) do
      {:ok, output} -> {:ok, output}
      :error -> :miss
    end
  end

  def recorded(_context, _name), do: :miss

  @doc "Write what a step produced; answers with the output that stands (first writer wins)."
  @spec record(map(), term(), term(), map()) :: {:ok, term()} | {:error, :terminal}
  def record(
        %{durable: %{store: store, store_module: mod, run_id: run_id}},
        name,
        output,
        meta \\ %{}
      ) do
    meta = Map.put_new(meta, :name, name)

    case mod.record(store, run_id, Key.for_name(name), Key.label(name), output, meta) do
      {:ok, cp} -> {:ok, cp.output}
      {:error, :terminal} -> {:error, :terminal}
    end
  end

  @doc "Write the failure about to roll the run back (the first error wins)."
  @spec record_error(map(), term()) :: :ok
  def record_error(%{durable: %{store: store, store_module: mod, run_id: run_id}}, error) do
    _ = mod.transition(store, run_id, :any, :unwinding, %{error: error})
    :ok
  end

  def record_error(_context, _error), do: :ok

  @doc "Mark a step's checkpoint as taken back and commit the run to rolling back."
  @spec mark_undone(map(), term()) :: :ok
  def mark_undone(%{durable: %{store: store, store_module: mod, run_id: run_id}}, name) do
    _ = mod.claim_undo(store, run_id, Key.for_name(name), AshPPlan.Reactor.Durable.Clock.now())
    _ = mod.transition(store, run_id, :any, :unwinding, %{})
    :ok
  end

  def mark_undone(_context, _name), do: :ok
end
