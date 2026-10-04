defmodule AshPPlan.MarketplaceSim.Endpoint do
  @moduledoc """
  Test-support endpoint for the marketplace-sim court, with a real serving mode.

  In tests: `server: false` (default — no inline server config, no Application
  env), Phoenix.LiveViewTest drives it through Phoenix.ConnTest.

  Serving mode: `bin/dashboard` boots it with `Application.put_env` setting
  `server: true` + bandit HTTP on `DASHBOARD_PORT` (default 4100). See
  `bin/dashboard_boot.exs`.

  AshAdmin branch decision ("strip for parts"): ash_pplan has exactly one Ash
  resource — `AshPPlan.Reactor.GenericActionBridge.Resource`, an internal test
  bridge declaring no user-facing domain (not in mix.exs, no Ash.Domain used as
  a user surface). Mounting AshAdmin over a synthetic bridge adds no admin
  surface, so this court takes the strip-for-parts branch: no AshAdmin mount,
  no AshPhoenix.Form — the dashboard runs real `Workflow.Runtime` runs through
  plain LiveView events instead.
  """

  use Phoenix.Endpoint,
    otp_app: :ash_pplan,
    secret_key_base: String.duplicate("a", 64),
    pubsub_server: AshPPlan.MarketplaceSim.PubSub,
    adapter: Bandit.PhoenixAdapter,
    render_errors: [view: AshPPlan.MarketplaceSim.ErrorView, accepts: ~w(html json)],
    live_view: [signing_salt: "mpsim2610"]

  plug(Plug.Session,
    store: :cookie,
    key: "mpsim_sid",
    signing_salt: "mpsim2610"
  )

  plug(AshPPlan.MarketplaceSim.Router)
end
