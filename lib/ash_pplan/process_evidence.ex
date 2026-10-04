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

  @doc "Pure OCEL 2.0 JSON export (objectTypes/eventTypes/objects/events)."
  @spec export([Event.t()], :ocel2_json) :: {:ok, String.t()} | {:error, map()}
  def export(events, :ocel2_json) when is_list(events) do
    # typed input gate: DateTime.to_iso8601/1 raises on anything but a DateTime,
    # so a non-DateTime timestamp is refused with the module's typed error shape
    # instead of crashing the whole export
    case Enum.find(events, &(not valid_timestamp?(&1))) do
      nil ->
        export_valid(events)

      %Event{id: id} ->
        {:error, %{reason: :invalid_timestamp, event: id}}
    end
  end

  def export(_events, format), do: {:error, %{reason: :unsupported_format, format: format}}

  defp valid_timestamp?(%Event{timestamp: %DateTime{}}), do: true
  defp valid_timestamp?(_), do: false

  defp export_valid(events) do
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

    doc = %{
      "objectTypes" => Enum.map(otypes, &%{"name" => &1, "attributes" => []}),
      "eventTypes" =>
        Enum.map(etypes, fn a ->
          keys =
            events
            |> Enum.filter(&(&1.activity == a))
            |> Enum.flat_map(&Map.keys(&1.attributes))
            |> Enum.map(&to_string/1)
            |> Enum.concat(["subject_id"])
            |> Enum.uniq()
            |> Enum.sort()

          # `subject_id` is declared because export/2 injects it into every event's
          # attributes below — omitting it here is an OCEL 2.0 attribute-closure
          # violation (every emitted event would carry an undeclared attribute)
          %{"name" => a, "attributes" => Enum.map(keys, &%{"name" => &1, "type" => "string"})}
        end),
      "objects" =>
        Enum.map(objects, fn {t, id, _q} -> %{"id" => id, "type" => t, "attributes" => []} end),
      "events" =>
        Enum.map(events, fn e ->
          %{
            "id" => e.id,
            "type" => e.activity,
            "time" => DateTime.to_iso8601(e.timestamp),
            "attributes" =>
              Enum.map(
                Map.put(e.attributes, :subject_id, e.subject_id),
                fn {k, v} -> %{"name" => to_string(k), "value" => value_to_s(v)} end
              ),
            "relationships" =>
              Enum.map(e.objects, fn {_t, id, q} -> %{"objectId" => id, "qualifier" => q} end)
          }
        end)
    }

    {:ok, Jason.encode!(doc)}
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
end
