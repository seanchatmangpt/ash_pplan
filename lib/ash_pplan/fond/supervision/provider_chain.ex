defmodule AshPPlan.FOND.Supervision.ProviderChain do
  def fetch([], _d, _i), do: {:error, :providers_exhausted}

  def fetch([p | rest], d, i) do
    case p.candidates(d, i) do
      {:ok, [_ | _] = cs} -> {:ok, p.id(), cs}
      _ -> fetch(rest, d, i)
    end
  end
end
