defmodule AshPPlan.Sim.Marketplace.Support do
  @moduledoc """
  Test support for the marketplace-sim reactors and court: starts a full
  in-process marketplace (Pub/Sub, Procurement API, portal, metering, billing)
  with real GenServer processes and a small bridge that adapts the
  ProcurementApi's `{:publish, topic, event}` cast into a real
  `Pubsub.publish/4` call so lifecycle events land on the simulated topic.
  """

  alias AshPPlan.Sim.Marketplace.Google.ProcurementApi
  alias AshPPlan.Sim.Marketplace.Google.Pubsub
  alias AshPPlan.Sim.Marketplace.Vendor.Portal
  alias Vendor.{Billing, MeteringServer}

  defmodule PubsubBridge do
    @moduledoc """
    Adapts ProcurementApi's `GenServer.cast(pubsub, {:publish, topic, event})`
    into a real ordered `Pubsub.publish/4` call on the simulated Pub/Sub.
    """

    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    end

    @impl true
    def init(opts), do: {:ok, %{target: Keyword.fetch!(opts, :target)}}

    @impl true
    def handle_cast({:publish, topic, event}, %{target: target} = state) do
      Pubsub.publish(target, topic, event, DateTime.utc_now() |> DateTime.to_iso8601())
      {:noreply, state}
    end
  end

  @doc """
  Starts one full marketplace for a court run. Returns a map of process ids:
  `%{pubsub:, bridge:, api:, portal:, metering:}`. Billing ETS tables are
  global and started idempotently.
  """
  @spec start_marketplace(keyword()) :: %{
          required(:pubsub) => pid(),
          required(:bridge) => pid(),
          required(:api) => pid(),
          required(:portal) => pid(),
          required(:metering) => pid()
        }
  def start_marketplace(opts \\ []) do
    secret = Keyword.get(opts, :secret, "marketplace-sim-secret")

    {:ok, pubsub} = Pubsub.start_link(name: nil)
    {:ok, bridge} = PubsubBridge.start_link(target: pubsub, name: nil)
    {:ok, api} = ProcurementApi.start_link(pubsub: bridge, name: nil)
    {:ok, portal} = Portal.start_link(secret: secret, name: nil)
    {:ok, metering} = MeteringServer.start_link(name: nil)
    :ok = Billing.start()

    %{pubsub: pubsub, bridge: bridge, api: api, portal: portal, metering: metering}
  end
end
