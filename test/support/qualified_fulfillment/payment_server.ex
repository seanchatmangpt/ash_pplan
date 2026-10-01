defmodule AshPPlan.Test.PaymentServer do
  @moduledoc """
  Real local HTTP payment authorizer (Bandit + Plug) on an ephemeral loopback port.

  `POST /payments/authorize` answers with the status returned by the `:mode`
  function (200, 402 or 503; default 200). Every request is counted.
  """
  @behaviour Plug
  import Plug.Conn

  @type t :: %{url: String.t(), stop: (-> :ok), counter: pid(), server: pid(), port: integer()}

  @spec start(keyword()) :: {:ok, t()}
  def start(opts \\ []) do
    mode = Keyword.get(opts, :mode, fn _n -> 200 end)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__, %{counter: counter, mode: mode}},
        port: 0,
        ip: :loopback,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    stop = fn ->
      safely(fn -> if Process.alive?(server), do: Supervisor.stop(server, :normal, 5_000) end)
      safely(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)
      :ok
    end

    {:ok,
     %{url: "http://127.0.0.1:#{port}", stop: stop, counter: counter, server: server, port: port}}
  end

  defp safely(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end

  @doc "Number of requests the server has received."
  @spec request_count(t() | pid()) :: non_neg_integer()
  def request_count(%{counter: c}), do: request_count(c)
  def request_count(c) when is_pid(c), do: Agent.get(c, & &1)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST", request_path: "/payments/authorize"} = conn, %{
        counter: counter,
        mode: mode
      }) do
    n = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

    case mode.(n) do
      200 -> json(conn, 200, ~s({"status":"authorized"}))
      402 -> json(conn, 402, ~s({"status":"declined"}))
      503 -> json(conn, 503, ~s({"status":"unavailable"}))
      other when is_integer(other) -> json(conn, other, ~s({"status":"error"}))
    end
  end

  def call(conn, %{counter: _}), do: send_resp(conn, 404, "not found")

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, body)
  end
end
