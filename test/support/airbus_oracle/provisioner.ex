defmodule AshPPlan.Test.AirbusOracle.Provisioner do
  @moduledoc """
  Manages the lifecycle and health verification of the Airbus Oracle Daemon.

  Follows the strict Chicago-style availability pattern established by
  `AshPPlan.Test.TLCCourt`:
  - When available: returns `:ok`
  - When absent in normal dev: returns `{:unavailable, reason}` for skip tagging
  - When absent under `ASH_PPLAN_REQUIRE_AIRBUS_ORACLE=1` (set by CI): raises,
    preventing silent skip of mandatory parity gates.
  """

  alias AshPPlan.Test.AirbusOracle.Client

  @doc """
  Evaluates whether the Airbus Oracle is available, or starts it if possible.
  """
  @spec availability() :: :ok | {:unavailable, term()}
  def availability do
    decide_availability(
      observe_availability(),
      System.get_env("ASH_PPLAN_REQUIRE_AIRBUS_ORACLE")
    )
  end

  @doc """
  Decides availability with fail-closed gate enforcement under mandatory CI mode.
  """
  @spec decide_availability(:ok | {:unavailable, term()}, String.t() | nil) ::
          :ok | {:unavailable, term()}
  def decide_availability(:ok, _require), do: :ok

  def decide_availability({:unavailable, reason}, "1") do
    raise """
    MANDATORY AIRBUS PARITY ORACLE UNAVAILABLE

    ASH_PPLAN_REQUIRE_AIRBUS_ORACLE=1 is set, but the oracle daemon is unreachable:
      #{inspect(reason)}

    To boot the oracle daemon locally:
      ./bin/airbus-oracle-boot
    Or set ORACLE_SOCKET_PATH to an active daemon socket.
    """
  end

  def decide_availability({:unavailable, reason}, _require) do
    {:unavailable, reason}
  end

  @doc """
  Probes socket or attempts in-process/background daemon boot.
  """
  @spec observe_availability() :: :ok | {:unavailable, term()}
  def observe_availability do
    case Client.ping(timeout: 1000) do
      :ok ->
        :ok

      {:error, _} ->
        # Try booting local python daemon if server.py exists and python3 is installed
        case try_boot_local_daemon() do
          :ok -> :ok
          {:error, boot_err} -> {:unavailable, boot_err}
        end
    end
  end

  defp try_boot_local_daemon do
    root = Path.expand("../../..", __DIR__)
    server_path = Path.join([root, "docker", "airbus_oracle", "server.py"])

    if File.exists?(server_path) and System.find_executable("python3") do
      socket_path = Client.socket_path()

      # Remove stale socket file if not accepting connections
      if File.exists?(socket_path) do
        File.rm(socket_path)
      end

      # Launch server.py in background
      port =
        Port.open(
          {:spawn_executable, System.find_executable("python3")},
          [
            :binary,
            args: [server_path],
            env: [{~c"ORACLE_SOCKET_PATH", to_charlist(socket_path)}]
          ]
        )

      # Register cleanup on VM exit
      Process.unlink(port)

      # Poll for readiness up to 5 seconds
      poll_until_ready(socket_path, 50, 100)
    else
      {:error, :python3_or_server_script_not_found}
    end
  end

  defp poll_until_ready(_socket_path, 0, _interval) do
    {:error, :oracle_boot_timeout}
  end

  defp poll_until_ready(socket_path, attempts_left, interval) do
    case Client.ping(timeout: interval) do
      :ok ->
        :ok

      {:error, _} ->
        :timer.sleep(interval)
        poll_until_ready(socket_path, attempts_left - 1, interval)
    end
  end
end
