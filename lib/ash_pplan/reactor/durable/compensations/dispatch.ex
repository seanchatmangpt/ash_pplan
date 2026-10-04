# GENERATED-PROVENANCE: ggen_igniter
#   template: packs/ash-runtime-integration-contract-pack/templates/durable_saga_compensation.ex.eex
#   subject:  AshPPlan.Reactor.Durable.Compensations.Dispatch
#   ontology: packs/rt-runtime-integration-contract-pack/ontology.ttl (rt:SagaCompensation)
#   Hand-editing this file is a refused transition: edit the ontology/template and re-sync.
defmodule AshPPlan.Reactor.Durable.Compensations.Dispatch do
  @moduledoc """
  Generated saga compensation delegate for `AshPPlan.Reactor.Durable.Steps.Dispatch`.

  `AshPPlan.Reactor.Durable.Steps.Dispatch` performs a real side effect on the durable ledger (it
  starts a child run via Engine.start/3 (a real durable-ledger side effect); the step has undo/4 but no compensate/4) and has no `compensate/4` of its own. This delegate supplies one:
  on failure it emits a typed undo event into the durable ledger (a store signal named
  `"ash_pplan.undo.dispatch"`) carrying the step identity, the failure reason and the
  ledger clock, so the engine's sweep and `Counterfactual.replay/3` signal redelivery can
  replay the undo from the ledger alone.

  Retry policy belongs to the durable engine, never the step: this callback NEVER returns
  `:retry`. It returns exactly the Reactor compensate contract
  (deps/reactor/lib/reactor/step.ex:60-64): `{:continue, value} | :ok | :retry |
  {:error | :retry, reason}` — here `:ok` on emission, and
  `{:error, {:saga_undo_refused, ...}}` as a typed refusal when no durable ledger
  context is available.
  """

  alias AshPPlan.Reactor.Durable.{Clock, Store.Ets}

  @step_module AshPPlan.Reactor.Durable.Steps.Dispatch
  @undo_prefix "ash_pplan.undo.dispatch"

  @undo_event_type :saga_undo

  @doc """
  Reactor `compensate/4`. Emits one typed undo event into the durable ledger for this
  step, then `:ok`.
  """
  @spec compensate(term(), map(), map(), keyword()) ::
          :ok | {:error, {:saga_undo_refused, term()}}
  def compensate(reason, arguments, context, _options) when is_map(context) do
    with %{durable: %{store: store, run_id: run_id} = durable} <- context,
         mod = Map.get(durable, :store_module, Ets),
         {:ok, _signal} <-
           mod.deliver_signal(store, run_id, @undo_prefix, %{
             type: @undo_event_type,
             step: to_string(@step_module),
             undo_name: @undo_prefix,
             reason: reason,
             arguments: arguments,
             at: Clock.now()
           }) do
      :ok
    else
      _ -> {:error, {:saga_undo_refused, {:no_durable_ledger_context, @step_module}}}
    end
  end

  def compensate(_reason, _arguments, _context, _options),
    do: {:error, {:saga_undo_refused, {:bad_context, @step_module}}}

  @doc false
  def can?(_step, :compensate), do: true
  def can?(_step, _capability), do: false
end
