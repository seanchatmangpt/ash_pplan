defmodule AshPPlan.Reactor.Middleware.Identity do
  @moduledoc """
  Reactor middleware that refuses to start (or resume) a run whose context lost
  its workflow subject, and stamps the run identity onto the context.

  Because `init/1` runs on both first start and resumption, a run replayed by
  `AshPPlan.Reactor.Durable.Engine` is re-bound to the same subject it halted under.
  """

  use Reactor.Middleware

  @key AshPPlan.Reactor.context_key()

  @impl true
  def init(context) do
    case context do
      %{@key => %{subject: "sha256:" <> _ = subject} = identity} ->
        {:ok, Map.put(context, @key, Map.put(identity, :bound_subject, subject))}

      _ ->
        {:error, %{reason: :missing_workflow_identity}}
    end
  end
end
