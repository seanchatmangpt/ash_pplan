defmodule AshPPlan.FOND.SupervisionSession do
  @moduledoc "Stateful-data facade over PolicySupervisor; callers persist the returned value."
  alias AshPPlan.FOND.PolicySupervisor

  def start(domain, initial, offers), do: PolicySupervisor.new(domain, initial, offers)

  def command(session) do
    with {:ok, choice} <- PolicySupervisor.next_action(session) do
      {:ok, Map.merge(choice, %{kind: :fond_policy_choice, do: false})}
    end
  end

  def outcome(session, command, outcome) do
    PolicySupervisor.observe(session, command.epoch, command.action, outcome)
  end

  def provider_lost(session, provider), do: PolicySupervisor.provider_down(session, provider)
  def provider_joined(session, offer), do: PolicySupervisor.add_provider(session, offer)
  def replan(session), do: PolicySupervisor.reselect(session)
end
