defmodule AshPPlan.Reactor.Durable.Checkpointed do
  @moduledoc """
  The step implementation every durable step is wrapped in.

  A recorded output comes back from `run/3` (not from a guard): Reactor keeps a guard-skipped
  step off its undo stack, so a replayed value returned that way could never be taken back.
  Replaying through the impl makes it an ordinary success that lands on the undo stack.

  The step about to run is put in the context as `:durable_step`, which is how a recording or
  halting step tells that it is the outer plan's own rather than a child of a nesting composite.
  A step that returns steps is planning and holds no checkpoint; its children are decorated.

  Design derived from mbuhot/magma (MIT per its mix.exs), re-implemented.
  """
  use Reactor.Step

  alias AshPPlan.Reactor.Durable.Run

  @impl true
  def run(arguments, context, options) do
    name = Keyword.fetch!(options, :durable_name)

    case Run.recorded(context, name) do
      {:ok, output} -> {:ok, output}
      :miss -> run_inner(arguments, context, options, name)
    end
  end

  defp run_inner(arguments, context, options, name) do
    inner = inner_step(context, options)
    ctx = context |> Map.put(:current_step, inner) |> Map.put(:durable_step, inner)

    inner
    |> Reactor.Step.run(arguments, ctx)
    |> handle(arguments, context, options, name)
  end

  defp handle({:ok, value, steps}, _arguments, context, _options, _name) when is_list(steps),
    do: {:ok, value, Enum.map(steps, &Run.decorate_step(&1, context))}

  defp handle({:ok, value}, arguments, context, options, name),
    do: Run.record(context, name, value, meta(options, arguments))

  defp handle(other, _arguments, _context, _options, _name), do: other

  @impl true
  def compensate(reason, arguments, context, options) do
    inner = inner_step(context, options)
    name = Keyword.fetch!(options, :durable_name)

    case Reactor.Step.compensate(inner, reason, arguments, %{context | current_step: inner}) do
      {:continue, value} ->
        case Run.record(context, name, value, meta(options, arguments)) do
          {:ok, recorded} -> {:continue, recorded}
          {:error, :terminal} -> :ok
        end

      other ->
        other
    end
  end

  @impl true
  def undo(value, arguments, context, options) do
    inner = inner_step(context, options)
    name = Keyword.fetch!(options, :durable_name)

    case Reactor.Step.undo(inner, value, arguments, %{context | current_step: inner}) do
      :ok -> Run.mark_undone(context, name)
      other -> other
    end
  end

  @impl true
  def can?(%{impl: {__MODULE__, options}} = step, capability),
    do: Reactor.Step.can?(%{step | impl: Keyword.fetch!(options, :durable_inner)}, capability)

  def can?(step, capability), do: super(step, capability)

  @impl true
  def async?(%{impl: {__MODULE__, options}} = step),
    do: Reactor.Step.async?(%{step | impl: Keyword.fetch!(options, :durable_inner)})

  def async?(step), do: super(step)

  @impl true
  def nested_steps(options) do
    case Keyword.fetch!(options, :durable_inner) do
      {module, inner} -> nested(module, inner)
      module -> nested(module, [])
    end
  end

  defp nested(module, inner) do
    if Code.ensure_loaded?(module) and function_exported?(module, :nested_steps, 1),
      do: module.nested_steps(inner),
      else: []
  end

  defp inner_step(context, options),
    do: %{context.current_step | impl: Keyword.fetch!(options, :durable_inner)}

  defp meta(options, arguments),
    do: %{
      impl: normalize(options[:durable_inner]),
      args: arguments,
      name: options[:durable_name]
    }

  defp normalize(m) when is_atom(m), do: {m, []}
  defp normalize(other), do: other
end
