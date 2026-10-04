defmodule AshPPlan.Sim.Marketplace.Reactors.SignupReactor do
  @moduledoc """
  Customer signup: verify the signup JWT (typed refusal on
  malformed/expired/wrong-audience), create the procurement account bound to
  the JWT subject, apply ENTITLEMENT_CREATION_REQUESTED, and assert the
  account state. Real ProcurementApi/Portal processes are passed as inputs.
  """

  use Reactor

  alias AshPPlan.Sim.Marketplace.Google.ProcurementApi
  alias AshPPlan.Sim.Marketplace.Vendor.Portal

  input :portal
  input :api
  input :jwt
  input :now
  input :aud
  input :account_id
  input :entitlement_id

  step :verify_jwt do
    argument :portal, input(:portal)
    argument :jwt, input(:jwt)
    argument :now, input(:now)
    argument :aud, input(:aud)

    run fn %{portal: portal, jwt: jwt, now: now, aud: aud}, _context ->
      case Portal.verify(portal, jwt, now: now, aud: aud) do
        {:ok, claims} -> {:ok, claims}
        {:error, reason} -> {:error, {:jwt_refused, reason}}
      end
    end
  end

  step :create_account do
    argument :api, input(:api)
    argument :account_id, input(:account_id)
    argument :claims, result(:verify_jwt)

    run fn %{api: api, account_id: account_id, claims: claims}, _context ->
      case ProcurementApi.create_account(api, account_id, customer_id: claims["sub"]) do
        {:ok, account} -> {:ok, account}
        {:error, reason} -> {:error, {:create_account_refused, reason}}
      end
    end
  end

  step :apply_creation_event do
    argument :api, input(:api)
    argument :entitlement_id, input(:entitlement_id)
    argument :account, result(:create_account)

    run fn %{api: api, entitlement_id: ent, account: account}, _context ->
      case ProcurementApi.apply_entitlement_event(
             api,
             ent,
             "ENTITLEMENT_CREATION_REQUESTED",
             "evt-" <> ent <> "-creation",
             account_id: account.id
           ) do
        {:ok, entitlement} -> {:ok, entitlement}
        {:error, reason} -> {:error, {:entitlement_event_refused, reason}}
      end
    end
  end

  step :assert_account do
    argument :api, input(:api)
    argument :account_id, input(:account_id)
    argument :entitlement, result(:apply_creation_event)

    run fn %{api: api, account_id: account_id, entitlement: entitlement}, _context ->
      with {:ok, account} <- ProcurementApi.get_account(api, account_id),
           :ok <-
             if(account.state == "ACCOUNT_CREATED",
               do: :ok,
               else: {:error, {:account_assertion_failed, account.state}}
             ),
           :ok <-
             if(entitlement.status == "ENTITLEMENT_ACTIVATION_REQUESTED",
               do: :ok,
               else: {:error, {:entitlement_assertion_failed, entitlement.status}}
             ) do
        {:ok, %{account: account, entitlement: entitlement}}
      end
    end
  end

  return :assert_account
end
