defmodule AshPPlan.Providers.Steps.DomainAction do
  @moduledoc """
  Reactor step running one Ash action against a resource.

  Options: `:resource`, `:action` (atom), `:kind` (`:create | :read | :update |
  :destroy | :action`). Arguments: `:input` (map, default `%{}`), `:record`
  (required for update/destroy), `:actor`. The action's own policies decide
  authorization; this step never bypasses them.
  """
  use Reactor.Step

  @impl true
  def run(arguments, _context, options) do
    resource = Keyword.fetch!(options, :resource)
    action = Keyword.fetch!(options, :action)
    kind = Keyword.fetch!(options, :kind)
    input = Map.get(arguments, :input) || %{}
    actor = Map.get(arguments, :actor)
    opts = [actor: actor, authorize?: Keyword.get(options, :authorize?, true)]

    do_run(kind, resource, action, input, Map.get(arguments, :record), opts)
  end

  defp do_run(:create, resource, action, input, _record, opts) do
    resource |> Ash.Changeset.for_create(action, input, opts) |> Ash.create()
  end

  defp do_run(:read, resource, action, input, _record, opts) do
    resource |> Ash.Query.for_read(action, input, opts) |> Ash.read()
  end

  defp do_run(:update, _resource, action, input, record, opts) when not is_nil(record) do
    record |> Ash.Changeset.for_update(action, input, opts) |> Ash.update()
  end

  defp do_run(:destroy, _resource, action, input, record, opts) when not is_nil(record) do
    record
    |> Ash.Changeset.for_destroy(action, input, opts)
    |> Ash.destroy(return_destroyed?: true)
  end

  defp do_run(:action, resource, action, input, _record, opts) do
    resource |> Ash.ActionInput.for_action(action, input, opts) |> Ash.run_action()
  end

  defp do_run(kind, _resource, _action, _input, _record, _opts) do
    {:error, %{reason: :invalid_domain_step, kind: kind}}
  end
end
