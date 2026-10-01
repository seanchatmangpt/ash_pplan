defmodule AshPPlan.Providers.Steps.Propose do
  @moduledoc """
  A2A step wrapping `AshPPlan.SA2A.Provider.propose/2`. Result is a candidate
  only (`authority: :none`); a candidate is never executed here.
  """
  use Reactor.Step

  @impl true
  def run(arguments, _context, options) do
    request = Map.fetch!(arguments, :request)

    case AshPPlan.SA2A.Provider.propose(request, Keyword.get(options, :opts, [])) do
      {:ok, candidate} -> {:ok, candidate}
      {:error, _} = error -> error
    end
  end
end
