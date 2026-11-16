defmodule AshPPlan.MirrorSim.Json do
  @moduledoc """
  JSON send helpers and the typed-refusal helper for the mirror-sim server.

  Refusals are `{"refused":true,"broken_term":"...","reason":"..."}`, HTTP 422 by default.
  """
  import Plug.Conn

  @doc "Send `data` as JSON with `status`."
  @spec send_json(Plug.Conn.t(), non_neg_integer(), term()) :: Plug.Conn.t()
  def send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, encode!(data))
  end

  @doc "Send a typed refusal."
  @spec refuse(Plug.Conn.t(), String.t() | atom(), term(), non_neg_integer()) :: Plug.Conn.t()
  def refuse(conn, broken_term, reason, status \\ 422) do
    send_json(conn, status, refusal(broken_term, reason))
  end

  @doc "Refusal body map."
  @spec refusal(String.t() | atom(), term()) :: map()
  def refusal(broken_term, reason) do
    %{"refused" => true, "broken_term" => to_string(broken_term), "reason" => to_text(reason)}
  end

  @doc "Encode to JSON; terms Jason cannot encode fall back to `inspect/1` strings."
  @spec encode!(term()) :: String.t()
  def encode!(data) do
    Jason.encode!(data)
  rescue
    _ -> Jason.encode!(%{"inspect" => inspect(data, limit: 50)})
  end

  @doc "Decode a JSON string."
  @spec decode(String.t()) :: {:ok, term()} | {:error, term()}
  def decode(bin) when is_binary(bin), do: Jason.decode(bin)

  defp to_text(t) when is_binary(t), do: t
  defp to_text(t), do: inspect(t, limit: 50)
end
