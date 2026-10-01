defmodule AshPPlan.FOND.SupervisionSession do
  @moduledoc """
  Composes FOND policy supervision with provider substitution.

  A session binds a powerless policy intent to a provider selected from the
  registry. Policy epoch and provider generation are independent fencing tokens.
  Provider loss can be observed without granting this module execution authority.
  """

  alias AshPPlan.FOND.{PolicySupervisor, ProviderRegistry}

  @enforce_keys [:policy, :registry, :requirements]
  defstruct [:policy, :registry, :requirements, :provider_id, :provider_generation]

  def start(policy, %ProviderRegistry{} = registry, requirements \\ [])
      when is_struct(policy, PolicySupervisor) do
    session = %__MODULE__{policy: policy, registry: registry, requirements: requirements}
    rebind(session)
  end

  def intent(%__MODULE__{} = session) do
    with {:ok, policy_intent} <- PolicySupervisor.intent(session.policy),
         {:ok, provider} <- fetch_bound_provider(session) do
      {:ok,
       %{
         policy: policy_intent,
         provider: provider,
         provider_generation: session.provider_generation
       }}
    end
  end

  def observe_outcome(%__MODULE__{} = session, policy_epoch, outcome) do
    with {:ok, policy} <- PolicySupervisor.observe(session.policy, policy_epoch, outcome) do
      {:ok, %{session | policy: policy}}
    end
  end

  def observe_provider_health(
        %__MODULE__{} = session,
        expected_generation,
        provider_id,
        healthy?
      ) do
    with {:ok, registry} <-
           ProviderRegistry.observe_health(
             session.registry,
             expected_generation,
             provider_id,
             healthy?
           ) do
      next = %{session | registry: registry}

      if provider_id == session.provider_id and not healthy? do
        rebind(next)
      else
        {:ok, next}
      end
    end
  end

  def replace_registry(%__MODULE__{} = session, %ProviderRegistry{} = registry) do
    rebind(%{session | registry: registry})
  end

  def rebind(%__MODULE__{} = session) do
    with {:ok, provider, generation} <-
           ProviderRegistry.select(session.registry, session.requirements) do
      {:ok, %{session | provider_id: provider.id, provider_generation: generation}}
    end
  end

  defp fetch_bound_provider(%__MODULE__{provider_id: nil}), do: {:error, :provider_unbound}

  defp fetch_bound_provider(%__MODULE__{} = session) do
    case Map.fetch(session.registry.providers, session.provider_id) do
      {:ok, %{healthy?: false}} -> {:error, {:provider_unhealthy, session.provider_id}}
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, {:provider_missing, session.provider_id}}
    end
  end
end
