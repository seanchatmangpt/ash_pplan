defmodule AshPPlan.FOND.Supervision do
  @moduledoc """
  Public powerless supervision facade for FOND policy portfolios.
  """

  alias AshPPlan.FOND.SupervisionSession

  def start(domain, initial, offers), do: SupervisionSession.start(domain, initial, offers)
  def intent(session), do: SupervisionSession.intent(session)
  def observe(session, action, outcome, epoch), do: SupervisionSession.observe(session, action, outcome, epoch)
  def provider_health(session, provider, health), do: SupervisionSession.provider_health(session, provider, health)
  def add_provider(session, offer, health \\ :up), do: SupervisionSession.add_provider(session, offer, health)
  def snapshot(session), do: SupervisionSession.snapshot(session)
end
