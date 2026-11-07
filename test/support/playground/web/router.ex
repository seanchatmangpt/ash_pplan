defmodule AshPPlan.Playground.Router do
  @moduledoc false

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {AshPPlan.Playground.Layouts, :root})
  end

  scope "/", AshPPlan.Playground do
    pipe_through(:browser)

    live("/", PlaygroundLive)
    live("/cop", PlaygroundLive)
  end
end
