# Boot script for the marketplace-sim serving endpoint (bin/dashboard).
# Starts PubSub + the test-support endpoint with server: true, then idles.
port =
  "DASHBOARD_PORT"
  |> System.get_env("4100")
  |> String.to_integer()

Application.put_env(:ash_pplan, AshPPlan.MarketplaceSim.Endpoint,
  server: true,
  http: [ip: {127, 0, 0, 1}, port: port],
  secret_key_base: String.duplicate("a", 64),
  pubsub_server: AshPPlan.MarketplaceSim.PubSub,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [view: AshPPlan.MarketplaceSim.ErrorView, accepts: ~w(html json)],
  live_view: [signing_salt: "mpsim2610"]
)

{:ok, _} = Supervisor.start_link(
  [
    {Phoenix.PubSub, name: AshPPlan.MarketplaceSim.PubSub},
    AshPPlan.MarketplaceSim.Endpoint
  ],
  strategy: :one_for_one,
  name: AshPPlan.MarketplaceSim.Supervisor
)

IO.puts("P-Plan dashboard listening on http://127.0.0.1:#{port}/ (explorer) and /dashboard")

Process.sleep(:infinity)
