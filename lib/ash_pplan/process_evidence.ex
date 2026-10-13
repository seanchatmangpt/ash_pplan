defmodule AshPPlan.ProcessEvidence do
  @moduledoc """
  Process evidence: events of a workflow run and a pure local OCEL 2.0 JSON export.

  Real integration with `Ex4pm`/`AshEx4pm` is UNSUPPORTED until those deps exist; this module
  does not reference them.
  """

  alias AshPPlan.ProcessEvidence.Event
  alias AshPPlan.ExecutionReceipt

  @callback events(run :: term()) :: [Event.t()]
  @callback export([Event.t()], format :: :ocel2_json) :: {:ok, String.t()} | {:error, map()}

  @doc """
  Turn a receipt plus subject into events: an `attempted`/`succeeded` pair per task (`failed`
  instead of `succeeded` for `opts[:failed_task]` or when the receipt did not succeed; tasks
  after a failure are not attempted).

  Options: `:tasks` (list of workflow tasks; default `[]`), `:realizations` (task id => term).
  """
  @spec events_from_receipt(ExecutionReceipt.t(), map(), keyword()) :: [Event.t()]
  def events_from_receipt(%ExecutionReceipt{} = r, subject, opts \\ []) do
    tasks = Keyword.get(opts, :tasks, [])
    reals = Keyword.get(opts, :realizations, %{})
    failed = Keyword.get(opts, :failed_task)
    run = "run:" <> ExecutionReceipt.run_identifier(r.run_id)
    sid = Map.get(subject, :id)
    ok? = r.status == :succeeded

    {evs, _} =
      Enum.reduce(tasks, {[], false}, fn t, {acc, dead?} ->
        if dead? do
          {acc, true}
        else
          id = to_string(t.id)
          cap = to_string(Map.get(t, :capability))
          real = to_string(Map.get(reals, t.id) || Map.get(reals, id) || "unrealized:" <> id)

          objs = [
            {"WorkflowRun", run, "run"},
            {"Capability", "cap:" <> cap, "capability"},
            {"Realization", "real:" <> real, "realization"}
          ]

          failed_here? = failed != nil and to_string(failed) == id
          base = %{task: id, status: to_string(r.status)}

          att = ev("#{run}/#{id}/attempted", "task_attempted", r.started_at, objs, base, sid)

          {last, dead} =
            cond do
              failed_here? ->
                {ev("#{run}/#{id}/failed", "task_failed", r.finished_at, objs, base, sid), true}

              ok? ->
                {ev("#{run}/#{id}/succeeded", "task_succeeded", r.finished_at, objs, base, sid),
                 false}

              true ->
                {nil, false}
            end

          {acc ++ [att] ++ List.wrap(last), dead}
        end
      end)

    evs
  end

  defp ev(id, act, ts, objs, attrs, sid),
    do: %Event{
      id: id,
      activity: act,
      timestamp: ts,
      objects: objs,
      attributes: attrs,
      subject_id: sid
    }

  @doc """
  Pure OCEL 2.0 JSON export (objectTypes/eventTypes/objects/events).

  Legacy envelope: attribute values are flattened to `[{name, value: string}]` pairs,
  `subject_id` is injected into every event's attributes (and declared on the event
  types so the attribute closure holds), and timestamps come straight from the events.
  Kept byte-identical for existing consumers; `export/3` is the corrected surface.
  """
  @spec export([Event.t()], :ocel2_json) :: {:ok, String.t()} | {:error, map()}
  def export(events, :ocel2_json) when is_list(events) do
    export(events, :ocel2_json, legacy: true)
  end

  def export(_events, format), do: {:error, %{reason: :unsupported_format, format: format}}

  @doc """
  Corrected OCEL 2.0 JSON export. Fixes named by the 2026-10-03 OCEL vocabulary audit:

    * `typed_attributes: true` (default) — attribute values keep their JSON types
      (integers stay integers, booleans stay booleans, date-times render as ISO8601
      strings, terms with no JSON rendering fall back to `inspect` as strings) and
      each eventTypes declaration carries the attribute's real type instead of a
      blanket `"string"`.
    * `subject_as_object: true` (default) — the event's `subject_id` is NOT injected
      into attributes; the subject is emitted as a first-class `Subject` object
      (`subject:<id>`) with a `subject`-qualifier relationship from each of its
      events. That is the OCEL-native identifier placement (an object identity, not
      an attribute).
    * `legacy: true` — reproduce the `export/2` envelope exactly (string-typed
      attributes, `subject_id` injected). Kept for byte-identical consumers.
  """
  @spec export([Event.t()], :ocel2_json, keyword()) :: {:ok, String.t()} | {:error, map()}
  def export(events, :ocel2_json, opts) when is_list(events) and is_list(opts) do
    # typed input gate: DateTime.to_iso8601/1 raises on anything but a DateTime,
    # so a non-DateTime timestamp is refused with the module's typed error shape
    # instead of crashing the whole export
    case Enum.find(events, &(not valid_timestamp?(&1))) do
      nil ->
        export_valid(events, opts)

      %Event{id: id} ->
        {:error, %{reason: :invalid_timestamp, event: id}}
    end
  end

  defp valid_timestamp?(%Event{timestamp: %DateTime{}}), do: true
  defp valid_timestamp?(_), do: false

  defp export_valid(events, opts) do
    # first-occurrence dedup by object id, O(N) via a map instead of Enum.uniq_by's O(N^2);
    # identical result (first occurrence kept, order preserved) so the JSON is byte-identical
    {objects_raw, _seen} =
      Enum.flat_map_reduce(events, %MapSet{}, fn e, seen ->
        Enum.reduce(e.objects, {[], seen}, fn {_t, id, _q} = o, {acc, seen} ->
          if MapSet.member?(seen, id),
            do: {acc, seen},
            else: {[o | acc], MapSet.put(seen, id)}
        end)
      end)

    objects =
      objects_raw
      |> Enum.reverse()
      |> Enum.sort()

    otypes = objects |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    etypes = events |> Enum.map(& &1.activity) |> Enum.uniq() |> Enum.sort()

    legacy? = Keyword.get(opts, :legacy, false)

    # corrected mode: the subject is a first-class object, not an attribute
    subjects =
      if legacy? do
        []
      else
        events
        |> Enum.map(& &1.subject_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(&{"Subject", "subject:" <> &1, "subject"})
      end

    all_objects =
      if legacy?, do: objects, else: Enum.sort(objects ++ subjects)

    doc = %{
      "objectTypes" => Enum.map(otypes, &%{"name" => &1, "attributes" => []}),
      "eventTypes" =>
        Enum.map(etypes, fn a ->
          evs = Enum.filter(events, &(&1.activity == a))

          keys =
            evs
            |> Enum.flat_map(&Map.keys(&1.attributes))
            |> Enum.map(&to_string/1)
            # `subject_id` is declared because the legacy envelope injects it into
            # every event's attributes — omitting it there is an OCEL 2.0
            # attribute-closure violation. The corrected envelope does not inject
            # it (the subject is a relationship to a `Subject` object), so it is
            # only declared in legacy mode.
            |> then(&if(legacy?, do: Enum.concat(&1, ["subject_id"]), else: &1))
            |> Enum.uniq()
            |> Enum.sort()

          attrs =
            if legacy? do
              Enum.map(keys, &%{"name" => &1, "type" => "string"})
            else
              evs
              |> Enum.flat_map(&Map.to_list(&1.attributes))
              |> Enum.map(fn {k, v} -> {to_string(k), attr_type(v)} end)
              |> Enum.into(%{})
              |> Enum.map(fn {name, type} -> %{"name" => name, "type" => type} end)
              |> Enum.sort_by(& &1["name"])
            end

          %{"name" => a, "attributes" => attrs}
        end),
      "objects" =>
        Enum.map(all_objects, fn {t, id, _q} -> %{"id" => id, "type" => t, "attributes" => []} end),
      "events" =>
        Enum.map(events, fn e ->
          %{
            "id" => e.id,
            "type" => e.activity,
            "time" => DateTime.to_iso8601(e.timestamp),
            "attributes" =>
              if legacy? do
                Enum.map(
                  Map.put(e.attributes, :subject_id, e.subject_id),
                  fn {k, v} -> %{"name" => to_string(k), "value" => value_to_s(v)} end
                )
              else
                e.attributes
                |> Enum.map(fn {k, v} -> %{name: to_string(k), value: json_value(v)} end)
                |> Enum.sort_by(& &1.name)
              end,
            "relationships" =>
              Enum.map(
                maybe_subject_rel(e, legacy?),
                fn {_t, id, q} -> %{"objectId" => id, "qualifier" => q} end
              )
          }
        end)
    }

    {:ok, Jason.encode!(doc)}
  end

  defp maybe_subject_rel(e, true), do: e.objects

  defp maybe_subject_rel(e, false) do
    case e.subject_id do
      nil -> e.objects
      sid -> e.objects ++ [{"Subject", "subject:" <> sid, "subject"}]
    end
  end

  # Attribute values are untyped term envelopes; scalars render via String.Chars, terms with
  # no protocol rendering (maps, tuples, structs) fall back to `inspect` instead of crashing
  # the whole export.
  defp value_to_s(v) when is_binary(v), do: v

  defp value_to_s(v) do
    to_string(v)
  rescue
    Protocol.UndefinedError -> inspect(v)
  end

  # corrected mode: JSON-native attribute values keep their JSON type; date-times
  # render as ISO8601 strings; terms with no JSON rendering (maps that are not JSON
  # objects, tuples, structs, pids) fall back to `inspect` as a string — lossy but
  # total, never a crash.
  defp json_value(v) when is_binary(v) or is_integer(v) or is_float(v) or is_boolean(v), do: v
  defp json_value(nil), do: nil
  defp json_value(v) when is_map(v) and not is_struct(v), do: v

  defp json_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp json_value(v) do
    inspect(v)
  end

  # corrected mode: per-attribute declared type matching json_value/1
  defp attr_type(v) when is_binary(v), do: "string"
  defp attr_type(v) when is_integer(v), do: "integer"
  defp attr_type(v) when is_float(v), do: "float"
  defp attr_type(v) when is_boolean(v), do: "boolean"
  defp attr_type(nil), do: "string"
  defp attr_type(v) when is_map(v) and not is_struct(v), do: "object"
  defp attr_type(%DateTime{}), do: "date-time"
  defp attr_type(_), do: "string"
end
