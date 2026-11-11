defmodule AshPPlan.Reactor.Steps.DomainAction do
  @moduledoc """
  Reactor step running one Ash action against a resource.

  Options: `:resource`, `:action` (atom), `:kind` (`:create | :read | :update |
  :destroy | :action`), `:authorize?` (boolean, default `true`), `:tenant`.
  Arguments: `:input` (map, default `%{}`), `:record` (required for
  update/destroy), `:actor`, `:tenant`. Caller `:actor` and `:tenant` also
  propagate from the Reactor `context` when not overridden in `arguments`.
  The action's own policies decide authorization; this step never bypasses them.
  """
  use Reactor.Step

  @impl true
  def run(arguments, context, options) do
    resource = Keyword.fetch!(options, :resource)
    action = Keyword.fetch!(options, :action)
    kind = Keyword.fetch!(options, :kind)
    input = map_get(arguments, :input) || %{}
    actor = map_get(arguments, :actor) || map_get(context, :actor) || Keyword.get(options, :actor)

    tenant =
      map_get(arguments, :tenant) || map_get(context, :tenant) || Keyword.get(options, :tenant)

    opts =
      [actor: actor, authorize?: Keyword.get(options, :authorize?, true)]
      |> maybe_put(:tenant, tenant)

    do_run(kind, resource, action, input, map_get(arguments, :record), opts)
  end

  defp do_run(:create, resource, action, input, _record, opts) do
    resource |> Ash.Changeset.for_create(action, input, opts) |> Ash.create(action_opts(opts))
  end

  defp do_run(:read, resource, action, input, _record, opts) do
    resource |> Ash.Query.for_read(action, input, opts) |> Ash.read(action_opts(opts))
  end

  defp do_run(:update, _resource, action, input, record, opts) when not is_nil(record) do
    record |> Ash.Changeset.for_update(action, input, opts) |> Ash.update(action_opts(opts))
  end

  defp do_run(:destroy, _resource, action, input, record, opts) when not is_nil(record) do
    record
    |> Ash.Changeset.for_destroy(action, input, opts)
    |> Ash.destroy([return_destroyed?: true] ++ action_opts(opts))
  end

  defp do_run(:action, resource, action, input, _record, opts) do
    resource
    |> Ash.ActionInput.for_action(action, input, opts)
    |> Ash.run_action(action_opts(opts))
    |> case do
      :ok -> {:ok, :ok}
      other -> other
    end
  end

  defp do_run(kind, _resource, _action, _input, _record, _opts) do
    {:error, %{reason: :invalid_domain_step, kind: kind}}
  end

  defp action_opts(opts), do: Keyword.take(opts, [:actor, :tenant, :authorize?])

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp map_get(map, key) when is_map(map), do: Map.get(map, key)
  defp map_get(_other, _key), do: nil
end
