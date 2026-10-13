defmodule AshPPlan.ProcessEvidence.Xaas do
  @moduledoc """
  Typed adapter from `AshPPlan.ProcessEvidence.Event` to the xaas canonical
  `Xaas.Telemetry.OcelNdjson` row shape (read-only reference:
  `/Users/sac/xaas/lib/xaas/telemetry/ocel_ndjson.ex` + the emitter that feeds it,
  and the authoritative court `Xaas.Ultracode.Ocel.Validator`).

  One row = one COMPLETE OCEL 2.0 document (what the xaas sink writes per line):
  `ocel:objectTypes` / `ocel:eventTypes` / `ocel:events` / `ocel:objects`, each a
  JSON array. The xaas assembly law accepts both bare-string and `%{"name" => t}`
  declarations; this adapter emits `%{"name" => t}` (spec-shaped, same as the
  corrected `ProcessEvidence.export/3`).

  ## Identifier mapping (`run:<id>/<task>@<seq>` vs the xaas UUID `ocel_id`)

  | ash_pplan | xaas row | notes |
  |---|---|---|
  | event id `run:<id>/<task>@<seq>` | `"ocel:events[].id"` | carried VERBATIM. xaas's law is only "unique non-empty string"; it does not require UUIDs (the emitter mints UUIDv7, but the court does not). `<seq>` guarantees intra-run uniqueness across re-attempts, `<id>` across runs. |
  | `event.activity` (`run_started`, `task_succeeded`, ...) | `"ocel:events[].type"` | verbatim; declared in `ocel:eventTypes`. xaas's PascalCase catalog is emitter-local vocabulary, not a court law. |
  | `event.timestamp` | `"ocel:events[].time"` | ISO8601; shifted to UTC so `DateTime.from_iso8601/1` returns offset 0 (the court's exact time law). |
  | object triple `{type, id, qualifier}` | relationship `%{"objectId" => id, "qualifier" => q}` + a row in `ocel:objects` | every relationship target is emitted as an object with `attributes: %{}` (the court's dangling-relationship law). |
  | `event.subject_id` | `Subject` object `subject:<id>` + `subject`-qualifier relationship | identifier placement, not an attribute (matches corrected `export/3`). |
  | `event.attributes` | `"ocel:events[].attributes"` | a JSON OBJECT (the xaas `attributes`-must-be-a-map law), values JSON-typed: binaries/integers/floats/booleans verbatim, `nil` verbatim, plain maps verbatim, `DateTime` as ISO8601, anything else `inspect`ed to a string (total, lossy, disclosed). |

  Zero-object events are NOT refused here — that is an xaas Ash-domain admission
  gate (`RelateEventToObjects`), not an OcelNdjson/Validator law — but every event
  the ledger paths build carries at least the run object.

  This module contains no validation law of its own: it converts and delegates
  (the same posture as `OcelNdjson` itself; the court stays authoritative).
  """

  alias AshPPlan.ProcessEvidence.Event

  @typedoc "One xaas OcelNdjson row: one complete OCEL 2.0 document (map form)."
  @type row :: map()

  @typedoc "One typed refusal: `reason` plus the offending event's index/id."
  @type refusal :: %{
          required(:reason) => :missing_identifier | :invalid_timestamp | :empty_identifier,
          required(:field) => :id | :activity | :timestamp | :object_id,
          required(:event) => String.t() | nil,
          optional(:event_index) => non_neg_integer(),
          optional(:value) => term()
        }

  @doc """
  Convert events to one xaas OcelNdjson row (map form).

  `{:ok, row}` | `{:error, refusal}` — fail-closed on a missing/empty event id or
  activity, a missing/empty referenced object id, or a non-`DateTime` timestamp
  (the sabotage twins: drop a required identifier and the conversion refuses with
  a typed error naming the field and event).
  """
  @spec to_row([Event.t()]) :: {:ok, row()} | {:error, refusal()}
  def to_row(events) when is_list(events) do
    with :ok <- check_events(events),
         :ok <- check_object_ids(events) do
      {:ok, build_row(events)}
    end
  end

  def to_row(other),
    do: {:error, %{reason: :missing_identifier, field: :id, event: nil, value: other}}

  @doc "Same as `to_row/1`, encoded as one ndjson line (trailing newline included)."
  @spec to_ndjson_line([Event.t()]) :: {:ok, String.t()} | {:error, refusal()}
  def to_ndjson_line(events) do
    case to_row(events) do
      {:ok, row} -> {:ok, Jason.encode!(row) <> "\n"}
      {:error, refusal} -> {:error, refusal}
    end
  end

  # -- gates ------------------------------------------------------------------

  defp check_events(events) do
    events
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {e, i}, :ok ->
      cond do
        not is_binary(e.id) or e.id == "" ->
          {:halt, {:error, refusal(:missing_identifier, :id, e, i)}}

        not is_binary(e.activity) or e.activity == "" ->
          {:halt, {:error, refusal(:missing_identifier, :activity, e, i)}}

        not is_struct(e.timestamp, DateTime) ->
          {:halt, {:error, refusal(:invalid_timestamp, :timestamp, e, i)}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp check_object_ids(events) do
    events
    |> Enum.with_index()
    |> Enum.flat_map(fn {e, i} -> Enum.map(e.objects, &{e, i, &1}) end)
    |> Enum.reduce_while(:ok, fn {e, i, {_t, oid, _q}}, :ok ->
      if is_binary(oid) and oid != "" do
        {:cont, :ok}
      else
        {:halt, {:error, refusal(:missing_identifier, :object_id, e, i)}}
      end
    end)
  end

  defp refusal(reason, field, e, i) do
    %{
      reason: reason,
      field: field,
      event: if(is_struct(e, Event), do: e.id, else: nil),
      event_index: i
    }
  end

  # -- conversion ---------------------------------------------------------------

  defp build_row(events) do
    event_types = events |> Enum.map(& &1.activity) |> Enum.uniq() |> Enum.sort()

    {objects, object_types} =
      events
      |> Enum.flat_map(& &1.objects)
      |> Enum.concat(subject_triples(events))
      |> Enum.uniq()
      |> Enum.map(fn {t, id, _q} ->
        {%{"id" => id, "type" => t, "attributes" => %{}, "relationships" => []}, t}
      end)
      |> then(fn pairs ->
        {Enum.map(pairs, &elem(&1, 0)),
         pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()}
      end)

    %{
      "ocel:objectTypes" => Enum.map(object_types, &%{"name" => &1}),
      "ocel:eventTypes" => Enum.map(event_types, &%{"name" => &1}),
      "ocel:events" =>
        Enum.map(events, fn e ->
          %{
            "id" => e.id,
            "type" => e.activity,
            "time" => e.timestamp |> to_utc() |> DateTime.to_iso8601(),
            "attributes" => Map.new(e.attributes, fn {k, v} -> {to_string(k), json_value(v)} end),
            "relationships" =>
              e.objects
              |> Enum.concat(subject_rel(e))
              |> Enum.map(fn {_t, id, q} -> %{"objectId" => id, "qualifier" => q} end)
          }
        end),
      "ocel:objects" => objects
    }
  end

  defp subject_triples(events) do
    events
    |> Enum.map(& &1.subject_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&{"Subject", "subject:" <> &1, "subject"})
  end

  defp subject_rel(%Event{subject_id: nil}), do: []
  defp subject_rel(%Event{subject_id: sid}), do: [{"Subject", "subject:" <> sid, "subject"}]

  defp to_utc(%DateTime{} = dt) do
    case DateTime.shift_zone(dt, "Etc/UTC") do
      {:ok, utc} -> utc
      # zone database unavailable: emit as-is (already ISO8601-representable)
      {:error, _} -> dt
    end
  end

  # JSON-native values verbatim (the xaas row keeps raw typed attribute values);
  # DateTime -> ISO8601; anything with no JSON rendering -> inspect (total, lossy).
  defp json_value(v) when is_binary(v) or is_integer(v) or is_float(v) or is_boolean(v), do: v
  defp json_value(nil), do: nil
  defp json_value(v) when is_map(v) and not is_struct(v), do: v
  defp json_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json_value(v), do: inspect(v)
end
