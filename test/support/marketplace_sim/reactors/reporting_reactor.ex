defmodule AshPPlan.Sim.Marketplace.Reactors.ReportingReactor do
  @moduledoc """
  Reporting: aggregates metered `plan_solve` usage over a half-open window,
  maps the total into a Service-Control-shaped payload (operationId,
  consumerId, metricValueSets with int64Value, startTime/endTime), ensures the
  committed billing pool exists (allocation is idempotent: an existing pool is
  never reset), records the drawdown against the pool idempotently by report
  ref, and returns the billing balance.
  """

  use Reactor

  alias Vendor.{Billing, MeteringServer}

  input :metering
  input :entitlement_id
  input :window_from
  input :window_to
  input :consumer_id
  input :report_ref
  input :pool_id
  input :pool_committed

  step :aggregate do
    argument :metering, input(:metering)
    argument :entitlement_id, input(:entitlement_id)
    argument :window_from, input(:window_from)
    argument :window_to, input(:window_to)

    run fn %{metering: metering, entitlement_id: ent, window_from: from, window_to: to},
           _context ->
      case MeteringServer.aggregate(metering, ent, {from, to}) do
        {:ok, total} -> {:ok, total}
        {:error, reason} -> {:error, {:aggregate_refused, reason}}
      end
    end
  end

  step :build_payload do
    argument :total, result(:aggregate)
    argument :report_ref, input(:report_ref)
    argument :consumer_id, input(:consumer_id)
    argument :window_from, input(:window_from)
    argument :window_to, input(:window_to)

    run fn %{
             total: total,
             report_ref: ref,
             consumer_id: consumer,
             window_from: from,
             window_to: to
           },
           _context ->
      {:ok,
       %{
         "operationId" => ref,
         "consumerId" => "project:" <> consumer,
         "metricValueSets" => [
           %{"metricName" => "plan_solve", "metricValues" => [%{"int64Value" => total}]}
         ],
         "startTime" => DateTime.from_unix!(from) |> DateTime.to_iso8601(),
         "endTime" => DateTime.from_unix!(to) |> DateTime.to_iso8601()
       }}
    end
  end

  step :ensure_pool do
    argument :pool_id, input(:pool_id)
    argument :pool_committed, input(:pool_committed)

    run fn %{pool_id: pool, pool_committed: committed}, _context ->
      case Billing.balance(pool) do
        {:error, :unknown_pool} -> {:ok, Billing.allocate(pool, committed)}
        {:ok, _balance} -> {:ok, :existing_pool_kept}
        other -> {:error, {:pool_refused, other}}
      end
    end
  end

  step :record_drawdown do
    argument :total, result(:aggregate)
    argument :pool_id, input(:pool_id)
    argument :report_ref, input(:report_ref)
    argument :pool, result(:ensure_pool)

    run fn %{total: total, pool_id: pool, report_ref: ref}, _context ->
      unless is_integer(total) and total > 0 do
        {:error, {:invalid_total, total}}
      else
        case Billing.record(pool, total, ref) do
          {:ok, outcome} when outcome in [:recorded, :duplicate] -> {:ok, outcome}
          {:error, reason} -> {:error, {:drawdown_refused, reason}}
        end
      end
    end
  end

  step :result do
    argument :payload, result(:build_payload)
    argument :total, result(:aggregate)
    argument :drawdown, result(:record_drawdown)
    argument :pool_id, input(:pool_id)

    run fn %{payload: payload, total: total, drawdown: drawdown, pool_id: pool}, _context ->
      {:ok, {committed, spent, remaining}} = Billing.balance(pool)

      {:ok,
       %{
         payload: payload,
         total: total,
         drawdown: drawdown,
         balance: %{committed: committed, spent: spent, remaining: remaining}
       }}
    end
  end

  return :result
end
