defmodule AshPPlan.FOND.SupervisionSession do
  @moduledoc """
  Pure runtime state joining FOND policy synthesis with provider substitution.

  A session carries two fences: policy epoch and provider generation. Outcomes
  advance policy state; provider observations may rebind the provider. Neither
  operation executes the selected action.
  """

  alias AshPPlan.FOND
  alias AshPPlan.FOND.ProviderRegistry
  alias AshPPlan.FOND.Synthesis

  @enforce_keys [:domain, :state, :mode, :policy, :epoch, :registry, :provider, :provider_generation]
  defstruct [:domain, :state, :mode, :policy, :epoch, :registry, :provider, :provider_generation, capabilities: []]

  @spec start(FOND.t(), FOND.state(), ProviderRegistry.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(%FOND{} = domain, initial, %ProviderRegistry{} = registry, opts \\ []) do
    mode = Keyword.get(opts, :mode, :strong_cyclic)
    capabilities = Keyword.get(opts, :capabilities, [])

    with {:ok, policy} <- Synthesis.synthesize(domain, initial, mode),
         {:ok, provider} <- ProviderRegistry.select(registry, capabilities) do
      {:ok, %__MODULE__{domain: domain, state: initial, mode: mode, policy: policy, epoch: 0,
        registry: registry, provider: provider.id, provider_generation: registry.generation,
        capabilities: capabilities}}
    end
  end

  @type t :: %__MODULE__{}

  @spec intent(t()) :: {:ok, map()} | {:error, map()}
  def intent(%__MODULE__{} = session) do
    cond do
      MapSet.member?(session.domain.goals, session.state) ->
        {:error, %{reason: :goal_reached, state: session.state}}
      not Map.has_key?(session.policy, session.state) ->
        {:error, %{reason: :missing_policy_action, state: session.state, epoch: session.epoch}}
      true ->
        {:ok, %{state: session.state, action: Map.fetch!(session.policy, session.state),
          provider: session.provider, epoch: session.epoch, provider_generation: session.provider_generation,
          authority: :none}}
    end
  end

  @spec observe_outcome(t(), FOND.state(), non_neg_integer()) :: {:ok, t()} | {:error, map()}
  def observe_outcome(%__MODULE__{} = session, outcome, expected_epoch) do
    with :ok <- fence_epoch(session, expected_epoch),
         {:ok, intent} <- intent(session),
         true <- outcome in FOND.outcomes(session.domain, session.state, intent.action) do
      case Synthesis.synthesize(session.domain, outcome, session.mode) do
        {:ok, policy} -> {:ok, %{session | state: outcome, policy: policy, epoch: session.epoch + 1}}
        {:error, error} -> {:error, %{reason: :policy_reselection_failed, error: error, outcome: outcome}}
      end
    else
      false -> {:error, %{reason: :unadmitted_outcome, state: session.state, outcome: outcome}}
      {:error, error} -> {:error, error}
    end
  end

  @spec observe_provider(t(), provider_id :: term(), boolean(), non_neg_integer()) :: {:ok, t()} | {:error, map()}
  def observe_provider(%__MODULE__{} = session, id, healthy?, expected_generation) do
    with {:ok, registry} <- ProviderRegistry.observe_health(session.registry, id, healthy?, expected_generation),
         {:ok, provider} <- select_after_observation(session, registry, id, healthy?) do
      {:ok, %{session | registry: registry, provider: provider.id, provider_generation: registry.generation}}
    end
  end

  defp select_after_observation(session, registry, id, false) when id == session.provider,
    do: ProviderRegistry.select(registry, session.capabilities, exclude: [id])
  defp select_after_observation(session, registry, _id, _healthy?),
    do: ProviderRegistry.select(registry, session.capabilities)

  defp fence_epoch(session, expected) when expected == session.epoch, do: :ok
  defp fence_epoch(session, expected),
    do: {:error, %{reason: :stale_policy_epoch, expected: expected, actual: session.epoch}}
end
