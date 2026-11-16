defmodule AshPPlan.MirrorSim.Wire do
  @moduledoc """
  Wire-level commit/replay/verify routes over the real `AshPPlan.RuntimeContract.*` modules.

  Mounted at `/wire/*`. Holds a receipt ledger in a named Agent (`Wire.Ledger`) so that
  tests can read state back after a refusal. The duplicate-replay-key rule and the digest
  tamper check are sim-level policy layered over the real modules.
  """
  use Plug.Router

  alias AshPPlan.MirrorSim.Json
  alias AshPPlan.RuntimeContract.{AuthorityGate, ExactSubject, Receipt, Replay}

  @max_body 65_536

  plug(:match)
  plug(:dispatch)

  defmodule Ledger do
    @moduledoc false
    use Agent

    def start_link(_opts \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def up?, do: Process.whereis(__MODULE__) != nil
    def get(key), do: Agent.get(__MODULE__, &Map.fetch(&1, key))
    def all, do: Agent.get(__MODULE__, & &1)

    @doc "Atomic insert-if-absent."
    def put_new(key, val) do
      Agent.get_and_update(__MODULE__, fn m ->
        if Map.has_key?(m, key), do: {:exists, m}, else: {:ok, Map.put(m, key, val)}
      end)
    end
  end

  @doc "Surface inventory for the router/parity compiler."
  def surfaces do
    [
      %{module: ExactSubject, fun: :exact?, arity: 1, route: "/wire/commit"},
      %{module: AuthorityGate, fun: :authorize, arity: 1, route: "/wire/commit"},
      %{module: Receipt, fun: :new, arity: 4, route: "/wire/commit"},
      %{module: Replay, fun: :replay, arity: 2, route: "/wire/replay"}
    ]
  end

  get "/state" do
    if Ledger.up?() do
      keys = Ledger.all() |> Map.keys() |> Enum.sort()
      Json.send_json(conn, 200, %{"count" => length(keys), "keys" => keys})
    else
      Json.refuse(conn, "ledger_down", "ledger not started", 503)
    end
  end

  post "/commit" do
    with :ok <- ledger(),
         {:ok, body, conn} <- body(conn),
         {:ok, key} <- replay_key(body),
         :ok <- subject(body),
         :ok <- authority(body) do
      receipt =
        Receipt.new(
          Map.fetch!(body, "subject"),
          Map.get(body, "action"),
          Map.get(body, "result"),
          key
        )

      stored = %{
        "subject" => receipt.subject,
        "action" => receipt.action,
        "result" => receipt.result,
        "replay_key" => key,
        "recorded_at" => DateTime.to_iso8601(receipt.recorded_at)
      }

      stored = Map.put(stored, "digest", digest(stored))

      case Ledger.put_new(key, stored) do
        :ok -> Json.send_json(conn, 201, stored)
        :exists -> Json.refuse(conn, "duplicate_replay_key", "receipt already committed")
      end
    else
      {:refuse, term, reason} -> Json.refuse(conn, term, reason)
    end
  end

  post "/replay" do
    with :ok <- ledger(),
         {:ok, body, conn} <- body(conn) do
      case Replay.replay(atomize_key(body), fn key ->
             case Ledger.get(key) do
               {:ok, stored} -> {:ok, stored}
               :error -> {:error, {:refused, :unknown_replay_key}}
             end
           end) do
        {:ok, stored} ->
          Json.send_json(conn, 200, stored)

        {:error, {:refused, :missing_replay_key}} ->
          Json.refuse(conn, "missing_replay_key", "replay_key absent or null")

        {:error, {:refused, term}} ->
          Json.refuse(conn, to_string(term), "replay refused")
      end
    else
      {:refuse, term, reason} -> Json.refuse(conn, term, reason)
    end
  end

  post "/verify" do
    with :ok <- ledger(),
         {:ok, body, conn} <- body(conn),
         {:ok, presented} <- object(Map.get(body, "receipt"), "receipt"),
         {:ok, key} <- replay_key(presented),
         {:ok, stored} <- fetch_stored(key) do
      fields = Map.take(presented, ["subject", "action", "result", "replay_key"])
      claimed = Map.get(presented, "digest")

      if digest(fields) == stored["digest"] and (claimed == nil or claimed == stored["digest"]) do
        Json.send_json(conn, 200, %{"verified" => true})
      else
        Json.refuse(conn, "tampered_receipt", "presented receipt differs from ledger")
      end
    else
      {:refuse, term, reason} -> Json.refuse(conn, term, reason)
    end
  end

  match _ do
    Json.refuse(conn, "no_route", "no wire route", 404)
  end

  # -- helpers ---------------------------------------------------------------

  defp ledger do
    if Ledger.up?(), do: :ok, else: {:refuse, "ledger_down", "ledger not started"}
  end

  defp body(conn) do
    # The router has already run Plug.Parsers; read the decoded body_params.
    declared =
      case Plug.Conn.get_req_header(conn, "content-length") do
        [n] -> String.to_integer(n)
        _ -> 0
      end

    cond do
      declared > @max_body ->
        {:refuse, "payload_too_large", "body exceeds #{@max_body} bytes"}

      match?(%Plug.Conn.Unfetched{}, conn.body_params) ->
        {:refuse, "malformed_json", "body not parsed"}

      match?(%{"_json" => _}, conn.body_params) and map_size(conn.body_params) == 1 ->
        {:refuse, "not_object", "body must be a JSON object"}

      true ->
        {:ok, conn.body_params, conn}
    end
  rescue
    ArgumentError -> {:refuse, "malformed_json", "bad content-length"}
  end

  defp object(%{} = m, _), do: {:ok, m}
  defp object(_, name), do: {:refuse, "not_object", "#{name} must be an object"}

  defp replay_key(body) do
    case Map.get(body, "replay_key") do
      k when is_binary(k) and byte_size(k) > 0 and byte_size(k) <= 256 -> {:ok, k}
      _ -> {:refuse, "missing_replay_key", "replay_key must be a non-empty string"}
    end
  end

  defp subject(body) do
    case Map.get(body, "subject") do
      %{"repo" => r, "base" => b, "head" => h}
      when is_binary(r) and is_binary(b) and is_binary(h) ->
        if ExactSubject.exact?(%{repo: r, base: b, head: h}),
          do: :ok,
          else: {:refuse, "subject_not_exact", "subject differs from exact identity"}

      _ ->
        {:refuse, "subject_not_exact", "subject missing or malformed"}
    end
  end

  defp authority(body) do
    gate_input =
      case Map.get(body, "authority") do
        %{"action" => a, "policy" => p} -> %{action: a, policy: p}
        %{"action" => a} -> %{action: a}
        _ -> %{}
      end

    case AuthorityGate.authorize(gate_input) do
      :ok -> :ok
      {:error, {:refused, :authority, action}} -> {:refuse, "authority", inspect(action)}
    end
  end

  defp fetch_stored(key) do
    case Ledger.get(key) do
      {:ok, s} -> {:ok, s}
      :error -> {:refuse, "unknown_replay_key", "no such receipt"}
    end
  end

  defp atomize_key(body) do
    case Map.fetch(body, "replay_key") do
      {:ok, k} -> %{replay_key: k}
      :error -> %{}
    end
  end

  defp digest(fields) do
    canon =
      Jason.encode!([
        fields["subject"],
        fields["action"],
        fields["result"],
        fields["replay_key"]
      ])

    :crypto.hash(:sha256, canon) |> Base.encode16(case: :lower)
  end
end
