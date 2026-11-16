defmodule AshPPlan.MirrorSim.Identity do
  @moduledoc """
  Two-probe identity: `GET /health` is 200 and unauthenticated `GET /api/health` is 401
  with body containing "missing or invalid Bearer token".
  """
  import Plug.Conn
  alias AshPPlan.MirrorSim.Json

  @bearer_msg "missing or invalid Bearer token"

  @doc "Handle `/health`."
  @spec health(Plug.Conn.t()) :: Plug.Conn.t()
  def health(conn),
    do: Json.send_json(conn, 200, %{"status" => "ok", "service" => "ash_pplan_mirror_sim"})

  @doc "Handle `/api/*`: always requires a Bearer token; the sim issues none, so 401."
  @spec api(Plug.Conn.t()) :: Plug.Conn.t()
  def api(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> tok] when byte_size(tok) > 0 ->
        Json.refuse(conn, "no_api_surface", "no authenticated surface in mirror sim", 404)

      _ ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> Json.send_json(401, %{"error" => @bearer_msg})
    end
  end

  @doc "The expected 401 message."
  @spec bearer_message() :: String.t()
  def bearer_message, do: @bearer_msg
end
