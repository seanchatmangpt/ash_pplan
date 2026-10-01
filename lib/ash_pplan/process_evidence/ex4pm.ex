defmodule AshPPlan.ProcessEvidence.Ex4pm do
  @moduledoc """
  Adapter mapping `AshPPlan.ProcessEvidence.Event` to `Ex4pm.Event` /
  `Ex4pm.EventRelationship` / `Ex4pm.EventLog`.

  Ex4pm is a test/dev-only dependency: every reference is guarded by `Code.ensure_loaded?/1` and
  made via `apply/3`/`struct!/2`, so this compiles without it. When absent (or `available?: false`
  is passed) every call returns `{:error, %{reason: :unsupported, detail: :ex4pm_not_available}}`.

  Ex4pm has no OCEL writer; `export/3` serializes the real `Ex4pm.EventLog` to OCEL 2.0 JSON and
  `parse/2` reads it back through the real reader `Ex4pm.OCEL.normalize/1`.
  """

  @behaviour AshPPlan.ProcessEvidence

  @unsupported {:error, %{reason: :unsupported, detail: :ex4pm_not_available}}

  @doc "True when Ex4pm structs and reader are loadable."
  def available? do
    Enum.all?(
      [
        Ex4pm.Event,
        Ex4pm.EventLog,
        Ex4pm.EventRelationship,
        Ex4pm.ObjectRef,
        Ex4pm.Subject,
        Ex4pm.OCEL
      ],
      &Code.ensure_loaded?/1
    )
  end

  defp ok?(opts), do: Keyword.get_lazy(opts, :available?, &available?/0)

  @impl true
  def events(_run), do: @unsupported

  @impl true
  def export(events, format \\ :ocel2_json), do: export(events, format, [])

  @doc "Export through Ex4pm.EventLog -> OCEL 2.0 JSON. Opts: `available?: boolean`."
  def export(events, :ocel2_json, opts) when is_list(events) do
    with {:ok, log} <- to_event_log(events, opts), do: {:ok, serialize(log)}
  end

  def export(_events, format, _opts), do: {:error, %{reason: :unsupported_format, format: format}}

  @doc "Map events to a list of Ex4pm.Event structs."
  def to_events(events, opts \\ []) when is_list(events) do
    if ok?(opts), do: {:ok, Enum.map(events, &map_event/1)}, else: @unsupported
  end

  @doc "Map events to an Ex4pm.EventLog."
  def to_event_log(events, opts \\ []) when is_list(events) do
    if ok?(opts) do
      evs = Enum.map(events, &map_event/1)

      objects =
        events
        |> Enum.flat_map(& &1.objects)
        |> Enum.uniq_by(fn {_t, id, _q} -> id end)
        |> Map.new(fn {t, id, _q} -> {id, struct!(Ex4pm.ObjectRef, id: id, type: t)} end)

      normalized = %{events: evs, objects: objects, object_relationships: []}

      {:ok,
       struct!(Ex4pm.EventLog,
         events: evs,
         objects: objects,
         subject: apply(Ex4pm.Subject, :new, [:event_log, normalized]),
         metadata: %{event_count: length(evs), object_count: map_size(objects)}
       )}
    else
      @unsupported
    end
  end

  @doc "Parse OCEL 2.0 JSON back into an Ex4pm.EventLog via the real Ex4pm reader."
  def parse(json, opts \\ []) when is_binary(json) do
    if ok?(opts) do
      with {:ok, raw} <- Jason.decode(json) do
        case apply(Ex4pm.OCEL, :normalize, [raw]) do
          {:ok, log} -> {:ok, log}
          {:error, reason} -> {:error, %{reason: :ex4pm_refused, detail: reason}}
        end
      end
    else
      @unsupported
    end
  end

  # Serialize an Ex4pm.EventLog to OCEL 2.0 JSON (objectTypes/eventTypes/objects/events).
  defp serialize(log) do
    objects = log.objects |> Map.values() |> Enum.sort_by(& &1.id)
    otypes = objects |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.sort()
    etypes = log.events |> Enum.map(& &1.activity) |> Enum.uniq() |> Enum.sort()

    doc = %{
      "objectTypes" => Enum.map(otypes, &%{"name" => &1, "attributes" => []}),
      "eventTypes" =>
        Enum.map(etypes, fn a ->
          keys =
            log.events
            |> Enum.filter(&(&1.activity == a))
            |> Enum.flat_map(&Map.keys(&1.attributes))
            |> Enum.map(&to_string/1)
            |> Enum.uniq()
            |> Enum.sort()

          %{"name" => a, "attributes" => Enum.map(keys, &%{"name" => &1, "type" => "string"})}
        end),
      "objects" => Enum.map(objects, &%{"id" => &1.id, "type" => &1.type, "attributes" => []}),
      "events" =>
        Enum.map(log.events, fn e ->
          %{
            "id" => e.id,
            "type" => e.activity,
            "time" => DateTime.to_iso8601(e.timestamp),
            "attributes" =>
              Enum.map(e.attributes, fn {k, v} ->
                %{"name" => to_string(k), "value" => to_string(v)}
              end),
            "relationships" =>
              Enum.map(
                e.relationships,
                &%{"objectId" => &1.object_id, "qualifier" => &1.qualifier}
              )
          }
        end)
    }

    Jason.encode!(doc)
  end

  defp map_event(e) do
    rels =
      Enum.map(e.objects, fn {_t, id, q} ->
        struct!(Ex4pm.EventRelationship, object_id: id, qualifier: q)
      end)

    struct!(Ex4pm.Event,
      id: e.id,
      activity: e.activity,
      timestamp: e.timestamp,
      object_ids: Enum.map(e.objects, fn {_t, id, _q} -> id end),
      relationships: rels,
      attributes: Map.put(e.attributes, :subject_id, e.subject_id)
    )
  end
end
