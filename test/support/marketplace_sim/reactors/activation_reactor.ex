defmodule AshPPlan.Sim.Marketplace.Reactors.ActivationReactor do
  @moduledoc """
  Entitlement activation with the race-condition safeguard: the procurement
  account is approved BEFORE the ENTITLEMENT_ACTIVE event is applied, so the
  activation can never observe an unapproved account. The lifecycle Pub/Sub
  event is published by the ProcurementApi on the state change; the reactor
  confirms the resource is ENTITLEMENT_ACTIVE before returning.
  """

  use Reactor

  alias AshPPlan.Sim.Marketplace.Google.ProcurementApi

  input :api
  input :account_id
  input :entitlement_id

  step :approve_account do
    argument :api, input(:api)
    argument :account_id, input(:account_id)

    run fn %{api: api, account_id: account_id}, _context ->
      case ProcurementApi.approve_account(api, account_id) do
        {:ok, account} -> {:ok, account}
        {:error, reason} -> {:error, {:approve_account_refused, reason}}
      end
    end
  end

  step :apply_active_event do
    argument :api, input(:api)
    argument :entitlement_id, input(:entitlement_id)
    argument :account, result(:approve_account)

    run fn %{api: api, entitlement_id: ent, account: account}, _context ->
      unless account.approved? do
        {:error, {:account_not_approved, account.state}}
      else
        case ProcurementApi.apply_entitlement_event(
               api,
               ent,
               "ENTITLEMENT_ACTIVE",
               "evt-" <> ent <> "-active"
             ) do
          {:ok, entitlement} -> {:ok, entitlement}
          {:error, reason} -> {:error, {:entitlement_event_refused, reason}}
        end
      end
    end
  end

  step :confirm_active do
    argument :api, input(:api)
    argument :entitlement_id, input(:entitlement_id)
    argument :entitlement, result(:apply_active_event)

    run fn %{api: api, entitlement_id: ent, entitlement: entitlement}, _context ->
      case ProcurementApi.get_entitlement(api, ent) do
        {:ok, live} when live.status == "ENTITLEMENT_ACTIVE" ->
          {:ok, %{entitlement: live, account_approved_before_activation?: true}}

        {:ok, live} ->
          {:error, {:activation_not_confirmed, live.status}}

        :error ->
          {:error, {:activation_not_confirmed, :entitlement_missing}}
      end
    end
  end

  return :confirm_active
end
