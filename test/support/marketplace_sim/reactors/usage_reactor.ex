defmodule AshPPlan.Sim.Marketplace.Reactors.UsageReactor do
  @moduledoc """
  Turns a completed durable workflow run into metered usage: runs a real
  `AshPPlan.Workflow.Runtime.run` through the durable ETS store, then posts
  one `plan_solve` usage event per completed run to the metering server,
  deduped by run id (the usage event id is `"plan_solve-" <> run_id`, and the
  metering server dedupes `(entitlement_id, usage_event_id)` pairs).
  """

  use Reactor

  alias AshPPlan.Examples.UltraCode.Steps
  alias Vendor.MeteringServer
  alias AshPPlan.Workflow.Runtime

  input :store
  input :run_id
  input :source
  input :inputs
  input :metering
  input :entitlement_id
  input :ts

  step :run_workflow do
    argument :store, input(:store)
    argument :run_id, input(:run_id)
    argument :source, input(:source)
    argument :inputs, input(:inputs)

    run fn %{store: store, run_id: run_id, source: source, inputs: inputs}, _context ->
      case Runtime.run(source, inputs,
             providers: [Steps.Local],
             store: store,
             run_id: run_id
           ) do
        {:ok, run} ->
          if run.observation.state == :succeeded do
            {:ok, run}
          else
            {:error, {:run_not_succeeded, run.observation.state}}
          end

        {:error, refusal} ->
          {:error, {:run_refused, refusal}}
      end
    end
  end

  step :post_usage do
    argument :metering, input(:metering)
    argument :entitlement_id, input(:entitlement_id)
    argument :run_id, input(:run_id)
    argument :run, result(:run_workflow)
    argument :ts, input(:ts)

    run fn %{metering: metering, entitlement_id: ent, run_id: run_id, ts: ts}, _context ->
      case MeteringServer.post_usage(
             metering,
             ent,
             "plan_solve-" <> run_id,
             "plan_solve",
             500,
             ts
           ) do
        {:ok, outcome} when outcome in [:recorded, :duplicate] -> {:ok, outcome}
        {:error, reason} -> {:error, {:post_usage_refused, reason}}
      end
    end
  end

  step :result do
    argument :run, result(:run_workflow)
    argument :usage, result(:post_usage)

    run fn %{run: run, usage: usage}, _context -> {:ok, %{run: run, usage: usage}} end
  end

  return :result
end
