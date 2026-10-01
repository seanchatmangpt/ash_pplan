defmodule AshPPlan.Examples.QualifiedFulfillment.Standing do
  @moduledoc """
  Observation of one qualified-fulfillment run, as input to the library standing API
  (`AshPPlan.Standing`). This module only READS the domain: the process-evidence events, the
  effect counters and collaborators, and real Ash state, manifest file and robot. Every verdict
  and the receipt are computed by `AshPPlan.Standing`.

  `run/1` takes the court context (`:model`, `:selection`, `:events`, `:effects`, `:collab`,
  `:dir`, `:order_id`, `:run_id`) and returns the run map `AshPPlan.Standing` consumes.
  """

  alias AshPPlan.Examples.QualifiedFulfillment.{Order, Shipment}
  alias AshPPlan.Test.{Effects, FulfillmentRobot, PaymentServer}

  require Ash.Query

  @after_payment ~w(produce_manifest prepare_worker pick_inventory await_pick verify_package
                    await_human_release commit_shipment schedule_followup establish_evidence)

  @doc "FOND gate of this domain: only an `authorized` payment has successors."
  def fond_gates,
    do: [%{task: "authorize_payment", admit: ["authorized"], successors: @after_payment}]

  @spec run(map()) :: map()
  def run(ctx) do
    {consequence, observation} = consequence(ctx.order_id, ctx)

    %{
      run_id: ctx.run_id,
      events: ctx.events,
      model: ctx.model,
      selection: ctx.selection,
      fond_gates: fond_gates(),
      execution: execution(ctx),
      consequence: consequence,
      observation: observation
    }
  end

  @doc "`{observed, wanted}` effect map: each physical or financial effect exactly once."
  def execution(%{effects: effects, collab: collab} = ctx) do
    expected = Map.get(ctx, :expected_effects, %{admit: 1, authorize: 1, commit: 1})
    counts = Effects.all(effects)
    picks = Map.get(counts, :pick_robot, 0) + Map.get(counts, :pick_manual, 0)

    observed = %{
      effects: Map.take(counts, Map.keys(expected)),
      picks: picks,
      payment_requests: payment_requests(collab.payment),
      robot_commands: FulfillmentRobot.command_count(collab.robot)
    }

    {observed, %{effects: expected, picks: 1, payment_requests: 1, robot_commands: 1}}
  end

  # A payment server that is gone cannot vouch for exactly-once: unreadable counts as a mismatch.
  defp payment_requests(payment) do
    PaymentServer.request_count(payment)
  catch
    :exit, _ -> :unreadable
  end

  @doc "Named checks over real state (order, shipment, manifest file, picked item) + the state."
  def consequence(order_id, %{collab: collab, dir: dir}) do
    order = Ash.get!(Order, order_id)
    shipments = Shipment |> Ash.Query.filter(order_id == ^order_id) |> Ash.read!()
    picked = :sys.get_state(collab.robot).sku

    checks = [
      order_fulfilled: order.status == :fulfilled,
      one_shipment: length(shipments) == 1,
      manifest_on_disk: File.exists?(Path.join(dir, "manifest-#{order_id}.txt")),
      picked_item_is_ordered_item: picked == order.sku
    ]

    {checks,
     %{
       order_id: order_id,
       order_status: order.status,
       shipments: length(shipments),
       picked_sku: picked
     }}
  end
end
