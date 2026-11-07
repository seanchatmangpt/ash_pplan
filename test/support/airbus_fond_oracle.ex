defmodule AshPPlan.Test.AirbusFondOracle do
  @moduledoc """
  `check_policy` client for the airbus-oracle daemon's FOND differential
  surface (lane A4).

  Lives beside — does not touch — `AshPPlan.Test.AirbusOracle.Client`
  (lane A3's JSON-RPC wrapper for the `solve` method). One JSON line per
  connection against `/tmp/airbus_oracle.sock`, same wire law:

      {"method": "check_policy", "params": {...}} ->
      {"id": ..., "result": {valid, strong_valid, strong_cyclic_valid, ...}}

  `transitions` is a list of `[state, action, [outcomes]]` triples because
  JSON object keys cannot be `(state, action)` tuples. The daemon rebuilds
  the tuple keys before handing the relation to autofde_lab's checker.
  """

  @socket_path "/tmp/airbus_oracle.sock"
  @timeout 5_000

  @doc """
  Sends one `check_policy` request. Returns the daemon's `result` object
  (a map with `valid`, `strong_valid`, `strong_cyclic_valid`,
  `reachable_states`, `non_goal_cycle_states`, ...) or `{:error, reason}`.

  `domain`/`policy`/`initial` are the native `AshPPlan.FOND` shapes with
  string states and actions; `semantics` is `"strong"` or
  `"strong_cyclic"` (the daemon returns BOTH semantics' verdicts regardless).
  """
  @spec check_policy(AshPPlan.FOND.t(), AshPPlan.FOND.policy(), AshPPlan.FOND.state(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def check_policy(%AshPPlan.FOND{} = domain, policy, initial, semantics)
      when semantics in ["strong", "strong_cyclic"] do
    case request(%{
           "method" => "check_policy",
           "params" => %{
             "initial" => initial,
             "goal_states" => Enum.sort(MapSet.to_list(domain.goals)),
             "transitions" => transitions_triples(domain),
             "policy" => stringify_policy(policy),
             "semantics" => semantics
           }
         }) do
      {:ok, %{"error" => nil} = result} -> {:ok, result}
      {:ok, %{"error" => error} = result} -> {:error, {:oracle_error, error, result}}
      other -> other
    end
  end

  @doc """
  Verdict-only convenience: `{:ok, %{strong: bool, strong_cyclic: bool}}`.
  """
  @spec verdicts(AshPPlan.FOND.t(), AshPPlan.FOND.policy(), AshPPlan.FOND.state()) ::
          {:ok, map()} | {:error, term()}
  def verdicts(domain, policy, initial) do
    with {:ok, result} <- check_policy(domain, policy, initial, "strong_cyclic") do
      {:ok,
       %{
         strong: result["strong_valid"],
         strong_cyclic: result["strong_cyclic_valid"],
         autofde: result
       }}
    end
  end

  @doc "Loud skip probe: `:ok` when the daemon is up, `{:error, reason}` otherwise."
  @spec ping(keyword()) :: :ok | {:error, term()}
  def ping(opts \\ []) do
    path = Keyword.get(opts, :socket_path, System.get_env("ORACLE_SOCKET_PATH") || @socket_path)
    timeout = Keyword.get(opts, :timeout, @timeout)

    payload =
      Jason.encode!(%{
        "method" => "check_policy",
        "params" => %{
          "initial" => "s0",
          "goal_states" => ["goal"],
          "transitions" => [["s0", "go", ["goal"]]],
          "policy" => %{"s0" => "go"},
          "semantics" => "strong"
        }
      })

    with {:ok, socket} <- connect(path, timeout),
         :ok <- :gen_tcp.send(socket, payload <> "\n"),
         {:ok, line} <- :gen_tcp.recv(socket, 0, timeout) do
      :gen_tcp.close(socket)

      case Jason.decode(line) do
        {:ok, %{"result" => %{"error" => nil, "valid" => true}}} -> :ok
        {:ok, %{"result" => %{"error" => err}}} -> {:error, {:oracle_error, err}}
        {:error, reason} -> {:error, {:json_decode_error, reason, line}}
      end
    else
      {:error, reason} -> {:error, {:connection_failure, reason}}
    end
  end

  defp transitions_triples(%AshPPlan.FOND{transitions: transitions}) do
    transitions
    |> Enum.flat_map(fn {state, actions} ->
      Enum.map(actions, fn {action, outcomes} ->
        [to_string(state), to_string(action), Enum.map(outcomes, &to_string/1)]
      end)
    end)
    |> Enum.sort()
  end

  defp stringify_policy(policy),
    do: Map.new(policy, fn {s, a} -> {to_string(s), to_string(a)} end)

  defp connect(path, timeout) do
    :gen_tcp.connect({:local, to_charlist(path)}, 0, [:binary, packet: :line, active: false],
      timeout
    )
  end

  defp request(payload, opts \\ []) do
    path = Keyword.get(opts, :socket_path, System.get_env("ORACLE_SOCKET_PATH") || @socket_path)
    timeout = Keyword.get(opts, :timeout, @timeout)

    with {:ok, socket} <- connect(path, timeout),
         :ok <- :gen_tcp.send(socket, Jason.encode!(payload) <> "\n"),
         {:ok, line} <- :gen_tcp.recv(socket, 0, timeout) do
      :gen_tcp.close(socket)

      case Jason.decode(line) do
        {:ok, %{"result" => result}} -> {:ok, result}
        {:error, reason} -> {:error, {:json_decode_error, reason, line}}
      end
    else
      {:error, reason} -> {:error, {:connection_failure, reason}}
    end
  end
end
