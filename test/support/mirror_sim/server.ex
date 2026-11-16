defmodule AshPPlan.MirrorSim.Server do
  @moduledoc """
  Bandit listener for the mirror-sim router. `start_link(port: 0)` binds an ephemeral
  loopback port; read it back with `port/1` / `base_url/1`.
  """
  alias AshPPlan.MirrorSim.Router

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :port, 0)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    Bandit.start_link(
      plug: Router,
      scheme: :http,
      ip: :loopback,
      port: Keyword.get(opts, :port, 0),
      startup_log: false
    )
  end

  @spec port(pid()) :: non_neg_integer()
  def port(pid) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  @spec base_url(pid()) :: String.t()
  def base_url(pid), do: "http://127.0.0.1:#{port(pid)}"
end
