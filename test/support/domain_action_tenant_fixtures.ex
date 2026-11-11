defmodule AshPPlan.Test.DomainActionTenantFixtures do
  @moduledoc """
  Real ETS-backed multitenant Ash resources and Reactor fixtures for
  `AshPPlan.Reactor.DomainActionTenantCourtTest`.
  """

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshPPlan.Test.DomainActionTenantFixtures.TenantNote
      resource AshPPlan.Test.DomainActionTenantFixtures.PlanGateway
    end
  end

  defmodule TenantNote do
    @moduledoc false
    use Ash.Resource,
      domain: AshPPlan.Test.DomainActionTenantFixtures.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      primary_read_warning?: false

    ets do
      private? false
    end

    multitenancy do
      strategy :attribute
      attribute :tenant_id
    end

    attributes do
      uuid_primary_key :id
      attribute :tenant_id, :string, allow_nil?: false, public?: true
      attribute :body, :string, allow_nil?: false, public?: true
    end

    actions do
      defaults [:destroy]

      read :read do
        primary? true
        argument :body, :string, allow_nil?: true
        filter expr(is_nil(^arg(:body)) or body == ^arg(:body))
      end

      create :create do
        accept [:body]
      end

      update :update do
        require_atomic? false
        accept [:body]
      end

      action :whoami, :map do
        run fn input, ctx ->
          {:ok,
           %{
             input_tenant: input.tenant,
             ctx_tenant: ctx.tenant,
             actor: ctx.actor
           }}
        end
      end

      action :ping do
        run fn _input, ctx ->
          if is_binary(ctx.tenant), do: :ok, else: {:error, :missing_tenant}
        end
      end
    end

    policies do
      policy always() do
        authorize_if actor_attribute_equals(:allowed?, true)
      end
    end
  end

  defmodule PlanGateway do
    @moduledoc false
    use Ash.Resource,
      domain: AshPPlan.Test.DomainActionTenantFixtures.Domain,
      data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      action :run_tenant_plan, :map do
        argument :plan_iri, :string, allow_nil?: false
        argument :input, :map, allow_nil?: true

        run {AshPPlan.Action.Run,
             plans: ["https://w3id.org/ash-pplan#SubscriptionRenewal"],
             handlers: %{
               "https://w3id.org/ash-pplan#AuthorizePayment" =>
                 {AshPPlan.Reactor.Steps.DomainAction,
                  [
                    resource: AshPPlan.Test.DomainActionTenantFixtures.TenantNote,
                    action: :create,
                    kind: :create
                  ]},
               "https://w3id.org/ash-pplan#RenewSubscription" =>
                 {AshPPlan.Reactor.Steps.DomainAction,
                  [
                    resource: AshPPlan.Test.DomainActionTenantFixtures.TenantNote,
                    action: :read,
                    kind: :read
                  ]}
             }}
      end
    end
  end

  defmodule TenantCrudReactor do
    @moduledoc false
    use Reactor

    alias AshPPlan.Reactor.Steps.DomainAction
    alias AshPPlan.Test.DomainActionTenantFixtures.TenantNote

    input :input

    step :create_note, {DomainAction, resource: TenantNote, action: :create, kind: :create} do
      argument :input, input(:input)
    end

    step :read_notes, {DomainAction, resource: TenantNote, action: :read, kind: :read} do
      wait_for :create_note
    end

    return :read_notes
  end
end
