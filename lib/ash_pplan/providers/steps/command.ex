defmodule AshPPlan.Providers.Steps.Command do
  @moduledoc """
  Command step: invokes a named local handler `{module, function}` with the
  step arguments. The handler is fixed in the options by the plan author; the
  step grants no authority beyond what the handler itself does.
  """
  use Reactor.Step

  @impl true
  def run(arguments, _context, options) do
    {m, f} = Keyword.fetch!(options, :handler)

    case apply(m, f, [arguments]) do
      {:ok, value} -> {:ok, %{command: Keyword.get(options, :name), result: value}}
      {:error, _} = error -> error
    end
  end
end
