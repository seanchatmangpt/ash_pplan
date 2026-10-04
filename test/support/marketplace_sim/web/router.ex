defmodule AshPPlan.MarketplaceSim.Router do
  @moduledoc false

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
  end

  scope "/", AshPPlan.MarketplaceSim do
    pipe_through(:browser)

    live("/", LifecycleLive)
    live("/dashboard", DashboardLive)
  end
end
