defmodule AshPPlan.FOND.SupervisionSession do
  @moduledoc "Immutable epoch and provider-generation fence for FOND supervision."
  @enforce_keys [:supervisor, :provider, :provider_generation]
  defstruct [:supervisor, :provider, :provider_generation]

  def new(supervisor, provider, generation) when is_integer(generation) and generation >= 0,
    do: {:ok, %__MODULE__{supervisor: supervisor, provider: provider, provider_generation: generation}}

  def observe(%__MODULE__{provider_generation: generation} = session, generation, epoch, outcome) do
    case AshPPlan.FOND.PolicySupervisor.observe(session.supervisor, epoch, outcome) do
      {:ok, supervisor} -> {:ok, %{session | supervisor: supervisor}}
      error -> error
    end
  end

  def observe(%__MODULE__{provider_generation: expected}, observed, _epoch, _outcome),
    do: {:error, %{reason: :stale_provider_generation, expected: expected, observed: observed}}

  def rebind(%__MODULE__{} = session, provider, generation)
      when is_integer(generation) and generation > session.provider_generation,
      do: {:ok, %{session | provider: provider, provider_generation: generation}}

  def rebind(%__MODULE__{provider_generation: expected}, _provider, observed),
    do: {:error, %{reason: :nonmonotonic_provider_generation, expected_after: expected, observed: observed}}
end
