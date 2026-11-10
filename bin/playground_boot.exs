# Boot script for the Tactical COP Playground serving endpoint (bin/playground).
# Starts PubSub + the test-support endpoint with server: true, then idles.
port =
  "PLAYGROUND_PORT"
  |> System.get_env("4200")
  |> String.to_integer()

Application.put_env(:ash_pplan, AshPPlan.Playground.Endpoint,
  server: true,
  http: [ip: {127, 0, 0, 1}, port: port],
  secret_key_base: String.duplicate("p", 64),
  pubsub_server: AshPPlan.Playground.PubSub,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [view: AshPPlan.Playground.ErrorView, accepts: ~w(html json)],
  live_view: [signing_salt: "cop_play_salt"]
)

{:ok, _} =
  Supervisor.start_link(
    [
      {Phoenix.PubSub, name: AshPPlan.Playground.PubSub},
      {AshPPlan.Playground.HiveSimulator, []},
      AshPPlan.Playground.Endpoint
    ],
    strategy: :one_for_one,
    name: AshPPlan.Playground.Supervisor
  )

IO.puts("Tactical COP Playground listening on http://127.0.0.1:#{port}/ (COP Flight Deck)")

Process.sleep(:infinity)
