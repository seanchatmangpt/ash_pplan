defmodule AshPPlan.Reactor.Steps.Actuate do
  @moduledoc """
  Actuation intent step. Constructs an intent descriptor and NEVER performs
  the actuation: `executed?` is always `false`. Execution of an intent needs
  a lease outside this library (authority ceiling is `:construct`).
  """
  use Reactor.Step

  @impl true
  def run(arguments, _context, options) do
    {:ok,
     %{
       intent: Keyword.get(options, :name),
       arguments: arguments,
       executed?: false,
       authority: :construct
     }}
  end
end
