defmodule AshPPlan.Examples.Selfhost.Steps do
  @moduledoc """
  Real Reactor steps of the self-hosting closure loop (observe, select, execute, integrate,
  verify, record standing) plus the deterministic local agent behind `Agent.Execute`.

  Every step reads and writes the `AshPPlan.Examples.Selfhost.Frontier` agent (an external real
  collaborator) keyed by the durable run id in `context.durable`. The execute step enforces the
  authority ceiling: the local agent may ask for any authority, and anything above `:construct`
  (in particular `:do`) is refused with `{:authority_exceeds_ceiling, authority}`; the run then
  fails, never reaches `record_standing`, and so holds no standing receipt. Nothing here grants
  DO authority.
  """

  @ceiling :construct
  @order "LOOP-CLOSURE-26.10.1-SELFHOST"

  @doc "The authority ceiling of the loop."
  @spec ceiling() :: atom()
  def ceiling, do: @ceiling

  @doc "The named loop-closure order every standing receipt carries."
  @spec closure_order() :: String.t()
  def closure_order, do: @order

  defmodule LocalAgent do
    @moduledoc "Deterministic local agent: the work product of an item is a digest of its id."

    @doc "Execute `item`; the result also states the authority the agent asks to use."
    @spec execute(map()) :: map()
    def execute(item) do
      %{id: item.id, digest: digest(item.id), authority: item.authority}
    end

    @doc "Recompute the digest of `id`."
    @spec digest(atom()) :: String.t()
    def digest(id),
      do: :crypto.hash(:sha256, "selfhost:" <> to_string(id)) |> Base.encode16(case: :lower)
  end

  defmodule Observe do
    @moduledoc "Observe the frontier: the items not yet closed."
    use Reactor.Step

    alias AshPPlan.Examples.Selfhost.Frontier

    @impl true
    def run(_arguments, _context, _options) do
      {:ok, %{open: Frontier.open()}}
    end
  end

  defmodule Select do
    @moduledoc "Select (claim) the next open item whose dependencies are closed."
    use Reactor.Step

    alias AshPPlan.Examples.Selfhost.Frontier

    @impl true
    def run(_arguments, context, _options) do
      with {:ok, id} <- Frontier.claim(context.durable.run_id), do: {:ok, %{selected: id}}
    end
  end

  defmodule Execute do
    @moduledoc "Run the local agent on the claimed item under the `:construct` ceiling."
    use Reactor.Step

    alias AshPPlan.Examples.Selfhost.{Frontier, Steps}
    alias AshPPlan.Examples.Selfhost.Steps.LocalAgent

    @impl true
    def run(_arguments, context, _options) do
      id = Frontier.claimed(context.durable.run_id)
      result = LocalAgent.execute(Frontier.item(id))

      if result.authority in [:none, :observe, :select, :plan, :construct] do
        :ok = Frontier.executed(id, result)

        {:ok,
         %{
           selected: id,
           digest: result.digest,
           authority: result.authority,
           ceiling: Steps.ceiling()
         }}
      else
        {:error, {:authority_exceeds_ceiling, result.authority}}
      end
    end
  end

  defmodule Integrate do
    @moduledoc "Integrate: close the claimed item in the frontier."
    use Reactor.Step

    alias AshPPlan.Examples.Selfhost.Frontier

    @impl true
    def run(_arguments, context, _options) do
      id = Frontier.claimed(context.durable.run_id)
      :ok = Frontier.close(id)
      {:ok, %{merged: id}}
    end
  end

  defmodule Verify do
    @moduledoc "Verify: the item is closed and its recorded digest recomputes."
    use Reactor.Step

    alias AshPPlan.Examples.Selfhost.Frontier
    alias AshPPlan.Examples.Selfhost.Steps.LocalAgent

    @impl true
    def run(_arguments, context, _options) do
      id = Frontier.claimed(context.durable.run_id)
      closed? = match?(%{status: :closed}, Frontier.item(id))

      if closed? and Frontier.result(id).digest == LocalAgent.digest(id) do
        {:ok, %{verified: id}}
      else
        {:error, {:verification_failed, id}}
      end
    end
  end

  defmodule Record do
    @moduledoc """
    Record the standing receipt of this run: identity, authority, consequence, replay, standing.
    Reached only by a run whose every earlier step succeeded.
    """
    use Reactor.Step

    alias AshPPlan.Examples.Selfhost.{Frontier, Steps}

    @impl true
    def run(_arguments, context, _options) do
      run_id = context.durable.run_id
      id = Frontier.claimed(run_id)

      receipt = %{
        identity: %{run: run_id, item: id, digest: Frontier.result(id).digest},
        authority: %{ceiling: Steps.ceiling(), granted: Frontier.result(id).authority},
        consequence: %{closed: id, open_after: Frontier.open()},
        replay: %{executions: Map.get(Frontier.executions(), id)},
        standing: :standing,
        loop_closure_order: Steps.closure_order()
      }

      :ok = Frontier.put_receipt(run_id, receipt)
      {:ok, receipt}
    end
  end
end
