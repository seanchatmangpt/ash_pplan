defmodule AshPPlan.Reactor.Steps.Await do
  @moduledoc """
  Provider-polled await/observe step.

  Option `:probe` is `{module, function, extra_args}`; it is called as
  `apply(module, function, [arguments | extra_args])` and returns
  `{:ok, value}` (condition holds), `:pending` (the Reactor halts, to be
  resumed and re-polled) or `{:error, reason}`. `mode: :observe` never halts:
  it returns `{:ok, %{observed: false}}` for pending.
  """
  use Reactor.Step

  @impl true
  def run(arguments, _context, options) do
    {m, f, extra} = Keyword.fetch!(options, :probe)

    case apply(m, f, [arguments | extra]) do
      {:ok, value} ->
        {:ok, %{observed: true, value: value}}

      :pending ->
        if Keyword.get(options, :mode, :await) == :observe do
          {:ok, %{observed: false, value: nil}}
        else
          {:halt, %{awaiting: Keyword.get(options, :name)}}
        end

      {:error, _} = error ->
        error
    end
  end
end
