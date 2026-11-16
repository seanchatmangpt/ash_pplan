defmodule AshPPlan.MirrorSim.Telemetry do
  @moduledoc """
  Mirror-sim area `/telemetry/*`: drives the real `AshPPlan.Telemetry.Emit.Event`
  constructors, a real `AshPPlan.Telemetry.Emit.BufferingEmitter`, the real
  `AshPPlan.ProcessEvidence.export/3` and the real `AshPPlan.ProcessEvidence.Ex4pm` adapter.

  Routes:

    * `POST /telemetry/emit`          body `{"type", "topic", ...fields}` -> envelope seq
    * `GET  /telemetry/drain`         NDJSON, one envelope per line (empties the ring)
    * `GET  /telemetry/counts`        buffered/evicted/by_type
    * `POST /telemetry/ocel/export`   body `{"events":[...], "legacy":bool}` -> OCEL 2.0 JSON
    * `POST /telemetry/ocel/ex4pm`    body `{"events":[...]}` -> OCEL 2.0 JSON via Ex4pm
    * `POST /telemetry/ocel/parse`    body `{"json": "<ocel>"}` -> events read by Ex4pm.OCEL

  The buffer is a named, unlinked `BufferingEmitter` owned by the sim (`stop_buffer/0` ends it).
  Refusals are typed 422 `{"refused":true,...}`.
  """
  use Plug.Router

  alias AshPPlan.MirrorSim.Json
  alias AshPPlan.ProcessEvidence
  alias AshPPlan.ProcessEvidence.Ex4pm
  alias AshPPlan.ProcessEvidence.Event, as: PEvent
  alias AshPPlan.Telemetry.Emit.BufferingEmitter
  alias AshPPlan.Telemetry.Emit.Event, as: E

  @buffer __MODULE__.Buffer

  plug(:match)
  plug(:dispatch)

  @doc "Surfaces mirrored by this area."
  @spec surfaces() :: [map()]
  def surfaces do
    [
      %{module: E, fun: :checkpoint_committed, arity: 3, route: "/telemetry/emit"},
      %{module: E, fun: :run_status_changed, arity: 4, route: "/telemetry/emit"},
      %{module: E, fun: :hazard_tripped, arity: 3, route: "/telemetry/emit"},
      %{module: E, fun: :lease_expired, arity: 2, route: "/telemetry/emit"},
      %{module: E, fun: :receipt_observed, arity: 3, route: "/telemetry/emit"},
      %{module: E, fun: :lease_granted, arity: 2, route: "/telemetry/emit"},
      %{module: E, fun: :lease_released, arity: 2, route: "/telemetry/emit"},
      %{module: E, fun: :invariant_refused, arity: 3, route: "/telemetry/emit"},
      %{module: E, fun: :wal_integrity, arity: 3, route: "/telemetry/emit"},
      %{module: BufferingEmitter, fun: :emit, arity: 2, route: "/telemetry/emit"},
      %{module: BufferingEmitter, fun: :drain, arity: 1, route: "/telemetry/drain"},
      %{module: BufferingEmitter, fun: :counts, arity: 1, route: "/telemetry/counts"},
      %{module: ProcessEvidence, fun: :export, arity: 3, route: "/telemetry/ocel/export"},
      %{module: Ex4pm, fun: :export, arity: 3, route: "/telemetry/ocel/ex4pm"},
      %{module: Ex4pm, fun: :parse, arity: 2, route: "/telemetry/ocel/parse"}
    ]
  end

  @doc "Stop the sim-owned buffer if running (test cleanup)."
  @spec stop_buffer() :: :ok
  def stop_buffer do
    case Process.whereis(@buffer) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: GenServer.stop(pid), else: :ok
    end
  catch
    :exit, _ -> :ok
  end

  @doc "Name of the sim-owned buffer."
  @spec buffer_name() :: atom()
  def buffer_name, do: @buffer

  post "/emit" do
    params = params(conn)

    with {:ok, type} <- fetch(params, "type"),
         {:ok, topic} <- fetch(params, "topic"),
         {:ok, event} <- build_event(type, params) do
      ensure_buffer()
      :ok = BufferingEmitter.emit(event, topic: topic, server: @buffer)
      %{buffered: n} = BufferingEmitter.counts(@buffer)
      Json.send_json(conn, 200, %{"emitted" => true, "type" => type, "buffered" => n})
    else
      {:refuse, term, reason} -> Json.refuse(conn, term, reason)
    end
  end

  get "/drain" do
    ensure_buffer()

    body =
      @buffer
      |> BufferingEmitter.drain()
      |> Enum.map_join("", fn env -> Json.encode!(envelope(env)) <> "\n" end)

    conn
    |> put_resp_content_type("application/x-ndjson")
    |> send_resp(200, body)
  end

  get "/counts" do
    ensure_buffer()
    c = BufferingEmitter.counts(@buffer)

    Json.send_json(conn, 200, %{
      "buffered" => c.buffered,
      "evicted" => c.evicted,
      "by_type" => Map.new(c.by_type, fn {k, v} -> {to_string(k), v} end)
    })
  end

  post "/ocel/export" do
    params = params(conn)

    with {:ok, raw} <- fetch(params, "events"),
         {:ok, events} <- decode_events(raw) do
      result =
        case params["legacy"] do
          true -> ProcessEvidence.export(events, :ocel2_json, legacy: true)
          _ -> ProcessEvidence.export(events, :ocel2_json, [])
        end

      respond_export(conn, result)
    else
      {:refuse, term, reason} -> Json.refuse(conn, term, reason)
    end
  end

  post "/ocel/ex4pm" do
    params = params(conn)

    with {:ok, raw} <- fetch(params, "events"),
         {:ok, events} <- decode_events(raw) do
      respond_export(conn, Ex4pm.export(events, :ocel2_json, []))
    else
      {:refuse, term, reason} -> Json.refuse(conn, term, reason)
    end
  end

  post "/ocel/parse" do
    case params(conn)["json"] do
      json when is_binary(json) ->
        case Ex4pm.parse(json, []) do
          {:ok, log} ->
            Json.send_json(conn, 200, %{
              "events" => Enum.map(log.events, &%{"id" => &1.id, "activity" => &1.activity})
            })

          {:error, %{reason: reason} = e} ->
            Json.refuse(conn, reason, inspect(Map.get(e, :detail)))

          {:error, other} ->
            Json.refuse(conn, "ocel_parse_failed", inspect(other, limit: 20))
        end

      _ ->
        Json.refuse(conn, "missing_field", "json (string) required")
    end
  end

  match _ do
    Json.refuse(
      conn,
      "unknown_route",
      "no telemetry route for #{conn.method} #{conn.request_path}",
      404
    )
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp respond_export(conn, {:ok, json}) when is_binary(json) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, json)
  end

  defp respond_export(conn, {:error, %{reason: reason} = e}),
    do: Json.refuse(conn, reason, inspect(Map.delete(e, :reason), limit: 20))

  defp respond_export(conn, {:error, other}),
    do: Json.refuse(conn, "export_failed", inspect(other, limit: 20))

  defp params(%Plug.Conn{body_params: %{} = p}) when not is_struct(p), do: p
  defp params(_), do: %{}

  defp fetch(params, key) do
    case Map.fetch(params, key) do
      {:ok, v} when not is_nil(v) -> {:ok, v}
      _ -> {:refuse, "missing_field", "#{key} required"}
    end
  end

  defp ensure_buffer do
    case Process.whereis(@buffer) do
      nil ->
        case GenServer.start(BufferingEmitter, [], name: @buffer) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _ ->
        :ok
    end
  end

  defp meta(params), do: if(is_map(params["meta"]), do: params["meta"], else: nil)

  defp build_event("checkpoint_committed", p) do
    with {:ok, run} <- fetch(p, "run_id"), {:ok, store} <- fetch(p, "store") do
      {:ok, E.checkpoint_committed(run, store, step_count: p["step_count"], meta: meta(p))}
    end
  end

  defp build_event("run_status_changed", p) do
    with {:ok, run} <- fetch(p, "run_id"),
         {:ok, from} <- fetch(p, "from"),
         {:ok, to} <- fetch(p, "to") do
      {:ok, E.run_status_changed(run, from, to, meta: meta(p))}
    end
  end

  defp build_event("hazard_tripped", p) do
    with {:ok, run} <- fetch(p, "run_id"), {:ok, hz} <- fetch(p, "hazard") do
      {:ok, E.hazard_tripped(run, hz, detail: p["detail"], meta: meta(p))}
    end
  end

  defp build_event("lease_expired", p) do
    with {:ok, id} <- fetch(p, "lease_id") do
      {:ok, E.lease_expired(id, owner: p["owner"], meta: meta(p))}
    end
  end

  defp build_event("receipt_observed", p) do
    with {:ok, run} <- fetch(p, "run_id"), {:ok, rid} <- fetch(p, "receipt_id") do
      {:ok, E.receipt_observed(run, rid, meta: meta(p))}
    end
  end

  defp build_event("lease_granted", p) do
    with {:ok, id} <- fetch(p, "lease_id") do
      {:ok, E.lease_granted(id, owner: p["owner"], meta: meta(p))}
    end
  end

  defp build_event("lease_released", p) do
    with {:ok, id} <- fetch(p, "lease_id") do
      {:ok, E.lease_released(id, owner: p["owner"], meta: meta(p))}
    end
  end

  defp build_event("invariant_refused", p) do
    with {:ok, run} <- fetch(p, "run_id"), {:ok, inv} <- fetch(p, "invariant") do
      {:ok, E.invariant_refused(run, inv, detail: p["detail"], meta: meta(p))}
    end
  end

  defp build_event("wal_integrity", p) do
    with {:ok, store} <- fetch(p, "store") do
      {:ok, E.wal_integrity(store, p["error"], run_id: p["run_id"], meta: meta(p))}
    end
  end

  defp build_event(type, _p), do: {:refuse, "unknown_event_type", inspect(type)}

  defp decode_events(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn raw, {:ok, acc} ->
      case decode_event(raw) do
        {:ok, ev} -> {:cont, {:ok, [ev | acc]}}
        {:refuse, _, _} = r -> {:halt, r}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  defp decode_events(_), do: {:refuse, "bad_events", "events must be a list"}

  defp decode_event(%{"id" => id, "activity" => act, "timestamp" => ts} = m)
       when is_binary(id) and is_binary(act) and is_binary(ts) do
    with {:ok, dt, _} <- DateTime.from_iso8601(ts),
         {:ok, objs} <- decode_objects(m["objects"] || []) do
      {:ok,
       %PEvent{
         id: id,
         activity: act,
         timestamp: dt,
         objects: objs,
         attributes: if(is_map(m["attributes"]), do: m["attributes"], else: %{}),
         subject_id: m["subject_id"]
       }}
    else
      {:error, _} -> {:refuse, "invalid_timestamp", "event #{id}: #{ts}"}
      {:refuse, _, _} = r -> r
    end
  end

  defp decode_event(_), do: {:refuse, "bad_event", "event needs string id, activity, timestamp"}

  defp decode_objects(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      [t, i, q], {:ok, acc} when is_binary(t) and is_binary(i) and is_binary(q) ->
        {:cont, {:ok, [{t, i, q} | acc]}}

      _, _ ->
        {:halt, {:refuse, "bad_object", "objects are [type, id, qualifier] string triples"}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  defp decode_objects(_), do: {:refuse, "bad_object", "objects must be a list"}

  defp envelope(env) do
    %{
      "seq" => env.seq,
      "topic" => jsonable(env.topic),
      "type" => to_string(env.type),
      "run_id" => jsonable(env.run_id),
      "emitted_at" => DateTime.to_iso8601(env.emitted_at),
      "data" => jsonable(env.data)
    }
  end

  defp jsonable(%DateTime{} = d), do: DateTime.to_iso8601(d)
  defp jsonable(%_{} = s), do: s |> Map.from_struct() |> jsonable()
  defp jsonable(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string(k), jsonable(v)} end)
  defp jsonable(l) when is_list(l), do: Enum.map(l, &jsonable/1)
  defp jsonable(v) when is_boolean(v) or is_nil(v), do: v
  defp jsonable(v) when is_atom(v), do: Atom.to_string(v)
  defp jsonable(v) when is_binary(v) or is_number(v), do: v
  defp jsonable(v), do: inspect(v, limit: 20)
end
