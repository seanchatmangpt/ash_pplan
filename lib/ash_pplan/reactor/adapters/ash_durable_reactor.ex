defmodule AshPPlan.Reactor.Adapters.AshDurableReactor do
  @moduledoc """
  Adapter for durable human-in-the-loop operations via `ash_durable_reactor`.

  `Human.Approve` -> `:human_approve` resolves to `Approve`, a `Reactor.Step`
  that halts until a decision arrives and exposes the `resume/4` callback that
  `AshDurableReactor.StepWrapper` dispatches to for resumable steps. The
  decision is one of `:approved`, `:refused`, `:still_waiting`; a still-waiting
  decision halts again. Without durable storage the halted Reactor is
  captured by `AshPPlan.Continuation`.
  """
  @behaviour AshPPlan.Reactor.Adapter

  defmodule Approve do
    @moduledoc """
    Halting approval step. Decision sources, first match wins: the
    `:decision` option, `context.private.decision` / `context.decision`
    (passed to `AshPPlan.Continuation.resume/4`), or the durable resume
    payload (`resume/4`). No decision halts with `%{awaiting: :approval}`.
    """
    use Reactor.Step

    @decisions [:approved, :refused, :still_waiting]

    @impl true
    def run(arguments, context, options) do
      decide(Keyword.get(options, :decision) || context_decision(context), arguments, options)
    end

    @doc "Durable resume callback used by `AshDurableReactor.StepWrapper`."
    def resume(arguments, context, options, persisted_step) do
      payload = persisted_step && Map.get(persisted_step, :resume_payload)

      decision =
        case payload do
          %{decision: d} -> d
          %{"decision" => d} -> d
          d when d in @decisions -> d
          _ -> nil
        end

      decide(decision || context_decision(context), arguments, options)
    end

    defp context_decision(context) do
      private = Map.get(context, :private)

      cond do
        is_map(private) and Map.get(private, :decision) -> private.decision
        Map.get(context, :decision) -> context.decision
        true -> nil
      end
    end

    defp decide(decision, arguments, _options) when decision in [:approved, :refused] do
      {:ok, %{decision: decision, outcome: decision, arguments: arguments}}
    end

    defp decide(_none_or_waiting, arguments, options) do
      {:halt,
       %{awaiting: :approval, approver: Keyword.get(options, :approver), arguments: arguments}}
    end
  end

  @table %{
    human_approve: {Approve, []}
  }

  @impl true
  def id, do: :ash_durable_reactor
  @impl true
  def available?, do: Code.ensure_loaded?(AshDurableReactor.StepWrapper)
  @impl true
  def ops, do: Map.keys(@table)
  @impl true
  def step(op, options), do: AshPPlan.Reactor.Adapter.resolve(__MODULE__, @table, op, options)
end
