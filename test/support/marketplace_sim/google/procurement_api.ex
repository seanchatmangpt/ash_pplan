defmodule AshPPlan.Sim.Marketplace.Google.ProcurementApi do
  @moduledoc """
  In-process simulation of the Google Cloud Commerce Partner Procurement API.

  Real state in the GenServer: accounts and entitlements with the 13-event
  entitlement state fold (ported from beam4pm-pro-entitlement-pack semantics,
  simplified to a sequence-ordered log). Every state transition publishes a
  lifecycle event to the simulated Pub/Sub topic.
  """

  use GenServer

  # The 13 Google event types and the status they fold to.
  @event_transitions %{
    "ENTITLEMENT_CREATION_REQUESTED" => "ENTITLEMENT_ACTIVATION_REQUESTED",
    "ENTITLEMENT_OFFER_ACCEPTED" => "ENTITLEMENT_ACTIVATION_REQUESTED",
    "ENTITLEMENT_ACTIVE" => "ENTITLEMENT_ACTIVE",
    "ENTITLEMENT_PLAN_CHANGE_REQUESTED" => "ENTITLEMENT_PENDING_PLAN_CHANGE_APPROVAL",
    "ENTITLEMENT_PLAN_CHANGED" => "ENTITLEMENT_ACTIVE",
    "ENTITLEMENT_PLAN_CHANGE_CANCELLED" => "ENTITLEMENT_ACTIVE",
    "ENTITLEMENT_PENDING_CANCELLATION" => "ENTITLEMENT_PENDING_CANCELLATION",
    "ENTITLEMENT_CANCELLING" => "ENTITLEMENT_PENDING_CANCELLATION",
    "ENTITLEMENT_CANCELLATION_REVERTED" => "ENTITLEMENT_ACTIVE",
    "ENTITLEMENT_RENEWED" => "ENTITLEMENT_ACTIVE",
    "ENTITLEMENT_CANCELLED" => "ENTITLEMENT_CANCELLED",
    "ENTITLEMENT_OFFER_ENDED" => :unchanged,
    "ENTITLEMENT_DELETED" => :unchanged
  }

  def event_transitions, do: Map.keys(@event_transitions)

  # -- client API --

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def create_account(api, account_id, attrs \\ %{}) do
    GenServer.call(api, {:create_account, account_id, attrs})
  end

  def approve_account(api, account_id) do
    GenServer.call(api, {:approve_account, account_id})
  end

  def reject_account(api, account_id, reason) do
    GenServer.call(api, {:reject_account, account_id, reason})
  end

  def get_account(api, account_id) do
    GenServer.call(api, {:get_account, account_id})
  end

  def get_entitlement(api, entitlement_id) do
    GenServer.call(api, {:get_entitlement, entitlement_id})
  end

  def apply_entitlement_event(api, entitlement_id, event_type, event_id, attrs \\ %{}) do
    GenServer.call(api, {:apply_event, entitlement_id, event_type, event_id, attrs})
  end

  def event_journal(api) do
    GenServer.call(api, :event_journal)
  end

  # -- server --

  @impl true
  def init(opts) do
    {:ok,
     %{
       pubsub: Keyword.get(opts, :pubsub),
       accounts: %{},
       entitlements: %{},
       journal: [],
       seq: 0
     }}
  end

  @impl true
  def handle_call({:create_account, id, attrs}, _from, st) do
    if Map.has_key?(st.accounts, id) do
      {:reply, {:error, :already_exists}, st}
    else
      account = %{
        id: id,
        state: "ACCOUNT_CREATED",
        customer_id: attrs[:customer_id] || "customer-" <> id,
        approved?: false
      }

      st = %{st | accounts: Map.put(st.accounts, id, account)}
      {:reply, {:ok, account}, st}
    end
  end

  def handle_call({:approve_account, id}, _from, st) do
    case Map.fetch(st.accounts, id) do
      {:ok, acct} ->
        acct = %{acct | state: "ACCOUNT_ACTIVE", approved?: true}
        {:reply, {:ok, acct}, %{st | accounts: Map.put(st.accounts, id, acct)}}

      :error ->
        {:reply, {:error, :not_found}, st}
    end
  end

  def handle_call({:reject_account, id, reason}, _from, st) do
    case Map.fetch(st.accounts, id) do
      {:ok, acct} ->
        acct = %{acct | state: "ACCOUNT_REJECTED", rejected_reason: reason}
        {:reply, {:ok, acct}, %{st | accounts: Map.put(st.accounts, id, acct)}}

      :error ->
        {:reply, {:error, :not_found}, st}
    end
  end

  def handle_call({:get_account, id}, _from, st) do
    {:reply, Map.fetch(st.accounts, id), st}
  end

  def handle_call({:get_entitlement, id}, _from, st) do
    {:reply, Map.fetch(st.entitlements, id), st}
  end

  def handle_call({:apply_event, ent_id, event_type, event_id, attrs}, _from, st) do
    cond do
      not Map.has_key?(@event_transitions, event_type) ->
        {:reply, {:error, {:unknown_event_type, event_type}}, st}

      st.journal |> Enum.any?(&match?(%{event_id: ^event_id}, &1)) ->
        # idempotent redelivery: exact no-op
        {:reply, {:ok, :duplicate}, st}

      true ->
        ent =
          Map.get(st.entitlements, ent_id, %{
            id: ent_id,
            account_id: attrs[:account_id],
            plan_id: attrs[:plan_id] || "edp-committed-tier-1",
            product_id: attrs[:product_id] || "ecosystem-enterprise-bundle",
            status: "ENTITLEMENT_STATE_UNSPECIFIED",
            last_event_id: nil
          })

        case transition(ent.status, event_type) do
          :unchanged ->
            ent = %{ent | last_event_id: event_id}
            st = record(st, ent_id, event_type, event_id)
            {:reply, {:ok, ent}, %{st | entitlements: Map.put(st.entitlements, ent_id, ent)}}

          new_status when is_binary(new_status) ->
            ent = %{ent | status: new_status, last_event_id: event_id}
            st = record(st, ent_id, event_type, event_id)
            st = %{st | entitlements: Map.put(st.entitlements, ent_id, ent)}

            publish(st, %{
              "eventType" => event_type,
              "entitlement" => %{"id" => ent_id, "plan" => ent.plan_id},
              "status" => ent.status
            })

            {:reply, {:ok, ent}, st}
        end
    end
  end

  def handle_call(:event_journal, _from, st) do
    {:reply, Enum.reverse(st.journal), st}
  end

  defp transition(status, event_type) do
    new = Map.fetch!(@event_transitions, event_type)

    cond do
      new == :unchanged ->
        :unchanged

      # CANCELLED/SUSPENDED are terminal-ish: refuse reactivation folds
      status == "ENTITLEMENT_CANCELLED" and new != "ENTITLEMENT_CANCELLED" ->
        {:error, :terminal_state}

      true ->
        new
    end
  end

  defp record(st, ent_id, event_type, event_id) do
    %{
      st
      | seq: st.seq + 1,
        journal: [
          %{seq: st.seq + 1, entitlement_id: ent_id, event_type: event_type, event_id: event_id}
          | st.journal
        ]
    }
  end

  defp publish(%{pubsub: nil}, _event), do: :ok

  defp publish(%{pubsub: pubsub}, event) do
    GenServer.cast(pubsub, {:publish, "google-procurement", event})
    :ok
  end
end
