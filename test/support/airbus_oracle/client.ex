defmodule AshPPlan.Test.AirbusOracle.Client do
  @moduledoc """
  UNIX domain socket client for communicating with the Airbus Deliberation Oracle daemon.
  Uses `:gen_tcp` in `{:local, path}` mode with line-delimited JSON-RPC 2.0 payloads.
  """

  @default_socket_path "/tmp/airbus_oracle.sock"
  @default_timeout 5000

  @doc """
  Sends a JSON-RPC 2.0 call to the oracle daemon.
  """
  @spec call(String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def call(method, params \\ %{}, opts \\ []) do
    socket_path = Keyword.get(opts, :socket_path, socket_path())
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    request_id = :erlang.unique_integer([:positive])

    payload = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "method" => method,
      "params" => params
    }

    with {:ok, json} <- Jason.encode(payload),
         {:ok, socket} <- connect(socket_path, timeout),
         :ok <- :gen_tcp.send(socket, json <> "\n"),
         {:ok, response_line} <- :gen_tcp.recv(socket, 0, timeout) do
      :gen_tcp.close(socket)

      case Jason.decode(response_line) do
        {:ok, %{"result" => result}} ->
          {:ok, result}

        {:ok, %{"error" => %{"message" => message} = error}} ->
          {:error, {:oracle_error, message, error}}

        {:error, decode_err} ->
          {:error, {:json_decode_error, decode_err, response_line}}
      end
    else
      {:error, reason} ->
        {:error, {:connection_failure, reason}}
    end
  end

  @doc "Pings the oracle daemon to verify liveness."
  @spec ping(keyword()) :: :ok | {:error, term()}
  def ping(opts \\ []) do
    case call("health_check", %{}, opts) do
      {:ok, %{"status" => "ok"}} -> :ok
      other -> {:error, other}
    end
  end

  def socket_path do
    System.get_env("ORACLE_SOCKET_PATH") || @default_socket_path
  end

  defp connect(socket_path, timeout) do
    path_charlist = to_charlist(socket_path)
    :gen_tcp.connect({:local, path_charlist}, 0, [:binary, packet: :line, active: false], timeout)
  end
end
