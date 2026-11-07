defmodule AshPPlan.Playground.Endpoint do
  @moduledoc """
  Serving and test endpoint for the Tactical Common Operating Picture (COP) Playground.

  In tests: driven via `Phoenix.LiveViewTest` and `Phoenix.ConnTest` with `server: false`.
  In serving mode: booted by `bin/playground` via Bandit HTTP adapter on port 4200.
  """

  use Phoenix.Endpoint,
    otp_app: :ash_pplan,
    secret_key_base: String.duplicate("p", 64),
    pubsub_server: AshPPlan.Playground.PubSub,
    adapter: Bandit.PhoenixAdapter,
    render_errors: [view: AshPPlan.Playground.ErrorView, accepts: ~w(html json)],
    live_view: [signing_salt: "cop_play_salt"]

  plug(Plug.Static,
    at: "/assets",
    from: "test/support/playground/priv/static",
    gzip: false
  )

  plug(Plug.Session,
    store: :cookie,
    key: "cop_play_sid",
    signing_salt: "cop_session_salt"
  )

  plug(AshPPlan.Playground.Router)
end
