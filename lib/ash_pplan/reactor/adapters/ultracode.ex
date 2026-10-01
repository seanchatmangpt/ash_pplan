defmodule AshPPlan.Reactor.Adapters.Ultracode do
  @moduledoc "Adapter for the UltraCode example workflow's in-repo steps."
  @behaviour AshPPlan.Reactor.Adapter

  alias AshPPlan.Examples.UltraCode.Steps

  @table %{
    repository_observe: {Steps.Observe, []},
    work_select: {Steps.Select, []},
    agent_execute: {Steps.Execute, [executor: :steady]},
    repository_integrate: {Steps.Integrate, []},
    verification_run: {Steps.Verify, []},
    evidence_record: {Steps.Record, []},
    authority_check: {Steps.CheckAuthority, []},
    # aliases used by the example's in-repo providers (Steps.Local / Steps.Flaky)
    work_observe: {Steps.Observe, []},
    work_integrate: {Steps.Integrate, []},
    verification_check: {Steps.Verify, []}
  }

  @impl true
  def id, do: :ultracode
  @impl true
  def available?, do: Code.ensure_loaded?(Steps.Observe)
  @impl true
  def ops, do: Map.keys(@table)
  @impl true
  def step(op, options), do: AshPPlan.Reactor.Adapter.resolve(__MODULE__, @table, op, options)
end
