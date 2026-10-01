defmodule AshPPlan.FOND.PolicySupervisor.Offers do
  @moduledoc """
  Pure FOND policy supervision. Selects among admitted policy offers, tracks a
  provider epoch, observes nondeterministic outcomes, and requests reselection.
  It has no execution or actuation surface.
  """
  alias AshPPlan.FOND

  defstruct [:domain, :state, :provider, :policy, :mode, epoch: 0, providers: %{}, history: []]
  @type t :: %__MODULE__{}

  def new(%FOND{} = domain, initial, offers) when is_list(offers) do
    with true <- MapSet.member?(domain.states, initial) || {:error, {:unknown_state, initial}},
         {:ok, chosen} <- select(domain, initial, offers) do
      {:ok,
       install(%__MODULE__{domain: domain, state: initial, providers: index(offers)}, chosen)}
    end
  end

  def select(domain, initial, offers) do
    offers
    |> Enum.flat_map(fn offer ->
      mode = Map.get(offer, :mode, :strong_cyclic)
      policy = Map.get(offer, :policy)
      provider = Map.get(offer, :provider)
      cost = Map.get(offer, :cost, 0)
      authority = Map.get(offer, :authority, :none)

      if authority == :none and provider != nil and is_map(policy) and
           match?({:ok, _}, FOND.validate_policy(domain, policy, initial, mode)) do
        [{rank(mode), cost, inspect(provider), offer}]
      else
        []
      end
    end)
    |> Enum.sort()
    |> case do
      [{_, _, _, offer} | _] -> {:ok, offer}
      [] -> {:error, :no_admissible_policy}
    end
  end

  def next_action(%__MODULE__{policy: policy, state: state, epoch: epoch, provider: provider}) do
    case Map.fetch(policy, state) do
      {:ok, action} ->
        {:ok, %{action: action, epoch: epoch, provider: provider, authority: :none}}

      :error ->
        {:error, {:no_policy_action, state}}
    end
  end

  def observe(%__MODULE__{} = s, epoch, action, outcome) do
    cond do
      epoch != s.epoch ->
        {:error, {:stale_epoch, epoch, s.epoch}}

      not MapSet.member?(s.domain.states, outcome) ->
        {:error, {:unknown_outcome, outcome}}

      action != Map.get(s.policy, s.state) ->
        {:error, {:stale_action, action, s.state}}

      outcome not in FOND.outcomes(s.domain, s.state, action) ->
        {:error, {:impossible_outcome, outcome}}

      true ->
        next = %{s | state: outcome, history: [{s.epoch, s.state, action, outcome} | s.history]}

        if MapSet.member?(s.domain.goals, outcome),
          do: {:ok, :goal, next},
          else: {:ok, :continue, next}
    end
  end

  def provider_down(%__MODULE__{} = s, provider) do
    providers = Map.delete(s.providers, provider)
    offers = Map.values(providers)

    with {:ok, chosen} <- select(s.domain, s.state, offers) do
      {:ok, install(%{s | providers: providers, epoch: s.epoch + 1}, chosen)}
    end
  end

  def add_provider(%__MODULE__{} = s, offer) do
    provider = Map.fetch!(offer, :provider)
    providers = Map.put(s.providers, provider, offer)
    {:ok, %{s | providers: providers}}
  end

  def reselect(%__MODULE__{} = s) do
    with {:ok, chosen} <- select(s.domain, s.state, Map.values(s.providers)) do
      {:ok, install(%{s | epoch: s.epoch + 1}, chosen)}
    end
  end

  def event(%__MODULE__{} = s, activity, attrs \\ %{}) do
    %{
      activity: activity,
      provider: s.provider,
      state: s.state,
      epoch: s.epoch,
      authority: :none,
      attributes: attrs
    }
  end

  defp install(s, offer),
    do: %{
      s
      | provider: offer.provider,
        policy: offer.policy,
        mode: Map.get(offer, :mode, :strong_cyclic)
    }

  defp index(offers), do: Map.new(offers, &{Map.fetch!(&1, :provider), &1})
  defp rank(:strong), do: 0
  defp rank(:strong_cyclic), do: 1
  defp rank(_), do: 9
end
