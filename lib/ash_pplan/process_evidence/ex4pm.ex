defmodule AshPPlan.ProcessEvidence.Ex4pm do
  @moduledoc """
  Adapter mapping `AshPPlan.ProcessEvidence.Event` to `Ex4pm.Event` /
  `Ex4pm.EventRelationship` / `Ex4pm.EventLog`.

  Ex4pm is not a dependency: every reference is guarded by `Code.ensure_loaded?/1` and made via
  `apply/3`/`struct!/2`. When absent every call returns
  `{:error, %{reason: :unsupported, detail: :ex4pm_not_available}}`. Real integration is
  UNSUPPORTED until the dep is added.
  """

  @behaviour AshPPlan.ProcessEvidence

  @unsupported {:error, %{reason: :unsupported, detail: :ex4pm_not_available}}

  @doc "True when Ex4pm.Event is loadable."
  def available?, do: Code.ensure_loaded?(Ex4pm.Event)

  @impl true
  def events(_run), do: @unsupported

  @impl true
  def export(events, format \\ :ocel2_json)

  def export(events, :ocel2_json) when is_list(events) do
    with {:ok, log} <- to_event_log(events),
         do: AshPPlan.ProcessEvidence.export(events, :ocel2_json) |> keep(log)
  end

  def export(_events, format), do: {:error, %{reason: :unsupported_format, format: format}}

  defp keep({:ok, json}, _log), do: {:ok, json}
  defp keep(other, _), do: other

  @doc "Map events to a list of Ex4pm.Event structs."
  def to_events(events) when is_list(events) do
    if available?() do
      {:ok, Enum.map(events, &map_event/1)}
    else
      @unsupported
    end
  end

  @doc "Map events to an Ex4pm.EventLog."
  def to_event_log(events) when is_list(events) do
    if available?() and Code.ensure_loaded?(Ex4pm.EventLog) and
         Code.ensure_loaded?(Ex4pm.ObjectRef) and Code.ensure_loaded?(Ex4pm.Subject) do
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
