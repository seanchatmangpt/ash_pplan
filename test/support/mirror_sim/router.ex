defmodule AshPPlan.MirrorSim.Router do
  @moduledoc """
  Mirror-sim router. Mounts each loaded area module at `/<area>/*`; `GET /surfaces` lists
  mounted and unmounted areas. Bad input never yields 500: JSON parse failures and handler
  exceptions become typed 4xx/422 refusals.
  """
  @behaviour Plug
  import Plug.Conn
  alias AshPPlan.MirrorSim.{Identity, Json}

  @areas %{
    "dsl" => AshPPlan.MirrorSim.Dsl,
    "state" => AshPPlan.MirrorSim.State,
    "reactor" => AshPPlan.MirrorSim.Reactor,
    "durable" => AshPPlan.MirrorSim.Durable,
    "providers" => AshPPlan.MirrorSim.Providers,
    "a2a" => AshPPlan.MirrorSim.A2A,
    "fond" => AshPPlan.MirrorSim.Fond,
    "tla" => AshPPlan.MirrorSim.TLA,
    "powl" => AshPPlan.MirrorSim.Powl,
    "standing" => AshPPlan.MirrorSim.Standing,
    "telemetry" => AshPPlan.MirrorSim.Telemetry,
    "oban" => AshPPlan.MirrorSim.Oban,
    "capability" => AshPPlan.MirrorSim.Capability,
    "mutation" => AshPPlan.MirrorSim.Mutation,
    "wire" => AshPPlan.MirrorSim.Wire,
    "coverage" => AshPPlan.MirrorSim.Coverage
  }

  @doc "Area name => module map (mounted or not)."
  @spec areas() :: %{String.t() => module()}
  def areas, do: @areas

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> parse_body()
    |> dispatch()
  rescue
    e -> Json.refuse(conn, "handler_exception", Exception.message(e))
  catch
    kind, reason -> Json.refuse(conn, "handler_#{kind}", inspect(reason, limit: 20))
  end

  defp parse_body(conn) do
    opts =
      Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason)

    Plug.Parsers.call(conn, opts)
  rescue
    e in Plug.Parsers.ParseError ->
      conn |> Json.refuse("malformed_json", Exception.message(e), 400) |> halt()

    _e in Plug.Parsers.RequestTooLargeError ->
      conn |> Json.refuse("body_too_large", "request body too large", 413) |> halt()
  end

  defp dispatch(%Plug.Conn{halted: true} = conn), do: conn

  defp dispatch(%Plug.Conn{method: "GET", path_info: ["health"]} = conn),
    do: Identity.health(conn)

  defp dispatch(%Plug.Conn{path_info: ["api" | _]} = conn), do: Identity.api(conn)
  defp dispatch(%Plug.Conn{method: "GET", path_info: ["surfaces"]} = conn), do: surfaces(conn)

  defp dispatch(%Plug.Conn{path_info: [area | rest]} = conn) do
    case Map.fetch(@areas, area) do
      {:ok, mod} ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :call, 2) do
          forward(conn, area, rest, mod)
        else
          Json.refuse(conn, "area_unmounted", "area #{area} is not mounted", 404)
        end

      :error ->
        not_found(conn)
    end
  end

  defp dispatch(conn), do: not_found(conn)

  defp forward(conn, area, rest, mod) do
    fwd = %{conn | path_info: rest, script_name: conn.script_name ++ [area]}
    out = mod.call(fwd, mod.init([]))
    %{out | path_info: conn.path_info, script_name: conn.script_name}
  end

  defp not_found(conn),
    do:
      Json.refuse(conn, "unknown_route", "no route for #{conn.method} #{conn.request_path}", 404)

  defp surfaces(conn) do
    {mounted, unmounted} =
      @areas
      |> Enum.sort()
      |> Enum.split_with(fn {_a, mod} ->
        Code.ensure_loaded?(mod) and function_exported?(mod, :call, 2)
      end)

    body = %{
      "mounted" =>
        Enum.map(mounted, fn {a, mod} ->
          %{"area" => a, "module" => inspect(mod), "surfaces" => area_surfaces(mod)}
        end),
      "unmounted" =>
        Enum.map(unmounted, fn {a, mod} -> %{"area" => a, "module" => inspect(mod)} end)
    }

    Json.send_json(conn, 200, body)
  end

  defp area_surfaces(mod) do
    if function_exported?(mod, :surfaces, 0) do
      Enum.map(mod.surfaces(), fn s ->
        %{
          "module" => inspect(s[:module]),
          "fun" => to_string(s[:fun]),
          "arity" => s[:arity],
          "route" => s[:route]
        }
      end)
    else
      []
    end
  rescue
    _ -> []
  end
end
