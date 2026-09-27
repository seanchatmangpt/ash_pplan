defmodule AshPPlan.FOND.SupervisionSession do
  @moduledoc "Immutable provider-aware FOND supervision session."
  alias AshPPlan.FOND
  alias AshPPlan.FOND.ProviderRegistry
  defstruct [:domain, :state, :policies, :registry, :selected, epoch: 0]

  def new(domain, state, policies, registry),
    do: choose(%__MODULE__{domain: domain, state: state, policies: policies, registry: registry})

  def provider_status(session, provider, status),
    do: choose(%{session | registry: ProviderRegistry.put(session.registry, provider, status), epoch: session.epoch + 1})

  def intent(%__MODULE__{selected: nil}), do: {:error, :no_policy}
  def intent(session) do
    case Map.fetch(session.selected.policy, session.state) do
      {:ok, action} -> {:ok, %{state: session.state, action: action, policy: session.selected.id,
        provider: session.selected.provider, epoch: session.epoch}}
      :error -> {:error, {:no_action, session.state}}
    end
  end

  def observe(session, epoch, action, outcome) when epoch == session.epoch do
    if outcome in FOND.outcomes(session.domain, session.state, action),
      do: {:ok, choose(%{session | state: outcome, epoch: epoch + 1})},
      else: {:error, {:unexpected_outcome, outcome}}
  end
  def observe(session, epoch, _, _), do: {:error, {:stale_epoch, epoch, session.epoch}}

  defp choose(session) do
    selected = session.policies
      |> Enum.filter(&ProviderRegistry.available?(session.registry, &1.provider))
      |> Enum.filter(&match?({:ok, _}, FOND.validate_policy(session.domain, &1.policy, session.state, &1.mode)))
      |> Enum.sort_by(&{if(&1.mode == :strong, do: 0, else: 1), Map.get(&1, :cost, 0), &1.provider, &1.id})
      |> List.first()
    %{session | selected: selected}
  end
end
