defmodule AshPPlan.Step.ReturnTerminals do
  @moduledoc false

  use Reactor.Step

  @impl true
  def run(arguments, _context, options) do
    terminals = Keyword.fetch!(options, :terminals)

    result =
      Map.new(terminals, fn {argument_name, step_iri} ->
        {step_iri, Map.fetch!(arguments, argument_name)}
      end)

    {:ok, result}
  end
end
