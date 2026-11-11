defmodule AshPPlan.Reactor.DomainActionTenantCourtTest do
  @moduledoc """
  Chicago court for `AshPPlan.Reactor.Steps.DomainAction` multi-tenant and
  caller-scope propagation.

  Uses a real ETS-backed multitenant Ash resource (`strategy :attribute`),
  real `Ash.Policy.Authorizer` policies, real `Reactor` runs, and the real
  `AshPPlan.Action.Run` generic-action boundary. No mocks.

  Anti-vacuity:
    * Missing tenant on an enforced multitenant resource is refused by Ash.
    * Tenant A reads never return Tenant B records.
    * Cross-tenant update and destroy attempts from Tenant B against a Tenant A
      record fail closed and leave Tenant A state intact.
    * Unauthorized actor is refused by `Ash.Policy.Authorizer`.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Adapters.AshReactor
  alias AshPPlan.Reactor.Steps.DomainAction
  alias AshPPlan.Test.DomainActionTenantFixtures.{PlanGateway, TenantCrudReactor, TenantNote}

  @plan "https://w3id.org/ash-pplan#SubscriptionRenewal"
  @actor %{id: "actor-1", allowed?: true}
  @denied_actor %{id: "actor-denied", allowed?: false}

  setup do
    Ash.DataLayer.Ets.stop(TenantNote)
    table = Ash.DataLayer.Ets.Info.table(TenantNote)

    wait_until(fn ->
      Process.whereis(Module.concat(table, TableManager)) == nil
    end)

    :ok
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("ETS TableManager did not stop")

      true ->
        Process.sleep(1)
        wait_until(fun, deadline)
    end
  end

  describe "caller tenant propagation across Ash.Changeset, Ash.Query, and Ash.ActionInput" do
    test "propagates context tenant and actor through create, read, update, destroy, and action" do
      ctx_a = %{tenant: "tenant-a", actor: @actor}
      ctx_b = %{tenant: "tenant-b", actor: @actor}

      assert {:ok, note_a} =
               DomainAction.run(
                 %{input: %{body: "alpha"}},
                 ctx_a,
                 resource: TenantNote,
                 action: :create,
                 kind: :create
               )

      assert note_a.tenant_id == "tenant-a"
      assert note_a.__metadata__.tenant == "tenant-a"

      assert {:ok, note_b} =
               DomainAction.run(
                 %{input: %{body: "beta"}},
                 ctx_b,
                 resource: TenantNote,
                 action: :create,
                 kind: :create
               )

      assert note_b.tenant_id == "tenant-b"

      # Ash.Query tenant isolation: each tenant sees only its own records.
      assert {:ok, [read_a]} =
               DomainAction.run(%{}, ctx_a, resource: TenantNote, action: :read, kind: :read)

      assert read_a.id == note_a.id
      assert read_a.body == "alpha"

      assert {:ok, [read_b]} =
               DomainAction.run(%{}, ctx_b, resource: TenantNote, action: :read, kind: :read)

      assert read_b.id == note_b.id
      assert read_b.body == "beta"

      # Ash.Changeset update within owning tenant succeeds.
      assert {:ok, updated_a} =
               DomainAction.run(
                 %{record: note_a, input: %{body: "alpha-v2"}},
                 ctx_a,
                 resource: TenantNote,
                 action: :update,
                 kind: :update
               )

      assert updated_a.body == "alpha-v2"
      assert updated_a.tenant_id == "tenant-a"

      # Anti-vacuity: cross-tenant update from tenant-b against tenant-a's record fails closed.
      assert {:error, _} =
               DomainAction.run(
                 %{record: updated_a, input: %{body: "hijacked"}},
                 ctx_b,
                 resource: TenantNote,
                 action: :update,
                 kind: :update
               )

      assert {:ok, [still_a]} =
               DomainAction.run(%{}, ctx_a, resource: TenantNote, action: :read, kind: :read)

      assert still_a.body == "alpha-v2"

      # Anti-vacuity: cross-tenant destroy from tenant-b against tenant-a's record leaves it intact.
      _ =
        DomainAction.run(
          %{record: updated_a},
          ctx_b,
          resource: TenantNote,
          action: :destroy,
          kind: :destroy
        )

      assert {:ok, [still_there]} =
               DomainAction.run(%{}, ctx_a, resource: TenantNote, action: :read, kind: :read)

      assert still_there.id == note_a.id

      # Same-tenant destroy removes the record.
      assert {:ok, destroyed_a} =
               DomainAction.run(
                 %{record: updated_a},
                 ctx_a,
                 resource: TenantNote,
                 action: :destroy,
                 kind: :destroy
               )

      assert destroyed_a.id == note_a.id

      assert {:ok, []} =
               DomainAction.run(%{}, ctx_a, resource: TenantNote, action: :read, kind: :read)

      # Generic action receives tenant and actor on ActionInput and context.
      assert {:ok, %{input_tenant: "tenant-b", ctx_tenant: "tenant-b", actor: @actor}} =
               DomainAction.run(
                 %{},
                 ctx_b,
                 resource: TenantNote,
                 action: :whoami,
                 kind: :action
               )

      # Void generic action returning :ok is normalized to {:ok, :ok} for Reactor.Step.
      assert {:ok, :ok} =
               DomainAction.run(
                 %{},
                 ctx_b,
                 resource: TenantNote,
                 action: :ping,
                 kind: :action
               )
    end

    test "step argument :tenant overrides context :tenant, which overrides option :tenant" do
      {:ok, _} =
        DomainAction.run(
          %{input: %{body: "from-arg"}, tenant: "tenant-arg", actor: @actor},
          %{tenant: "tenant-ctx"},
          resource: TenantNote,
          action: :create,
          kind: :create,
          tenant: "tenant-opt"
        )

      assert {:ok, [rec]} =
               DomainAction.run(
                 %{actor: @actor},
                 %{},
                 resource: TenantNote,
                 action: :read,
                 kind: :read,
                 tenant: "tenant-arg"
               )

      assert rec.body == "from-arg"

      assert {:ok, []} =
               DomainAction.run(
                 %{actor: @actor, tenant: "tenant-ctx"},
                 %{},
                 resource: TenantNote,
                 action: :read,
                 kind: :read
               )
    end

    test "anti-vacuity: missing tenant on multitenant resource is refused, and policy still enforces actor" do
      assert {:error, %Ash.Error.Invalid{}} =
               DomainAction.run(
                 %{input: %{body: "orphan"}, actor: @actor},
                 %{},
                 resource: TenantNote,
                 action: :create,
                 kind: :create
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               DomainAction.run(
                 %{input: %{body: "denied"}},
                 %{tenant: "tenant-a", actor: @denied_actor},
                 resource: TenantNote,
                 action: :create,
                 kind: :create
               )

      assert {:error, %{reason: :invalid_domain_step, kind: :update}} =
               DomainAction.run(
                 %{input: %{body: "no-record"}},
                 %{tenant: "tenant-a", actor: @actor},
                 resource: TenantNote,
                 action: :update,
                 kind: :update
               )

      assert {:error, %{reason: :invalid_domain_step, kind: :bogus}} =
               DomainAction.run(
                 %{},
                 %{tenant: "tenant-a", actor: @actor},
                 resource: TenantNote,
                 action: :read,
                 kind: :bogus
               )
    end
  end

  describe "Reactor and AshPPlan.Action.Run integration" do
    test "Reactor.run propagates context tenant and actor to DomainAction steps" do
      assert {:ok, {DomainAction, [kind: :create, resource: TenantNote, action: :create]}} =
               AshReactor.step(:domain_create, resource: TenantNote, action: :create)

      assert {:ok, [created]} =
               Reactor.run(
                 TenantCrudReactor,
                 %{input: %{body: "reactor-scoped"}},
                 %{tenant: "tenant-rx", actor: @actor}
               )

      assert created.body == "reactor-scoped"
      assert created.tenant_id == "tenant-rx"
    end

    test "AshPPlan.Action.Run transfers Ash caller scope (tenant + actor) into DomainAction steps" do
      assert {:ok, %{outcome: {:ok, [record]}, receipt: %{status: :succeeded}}} =
               PlanGateway
               |> Ash.ActionInput.for_action(
                 :run_tenant_plan,
                 %{plan_iri: @plan, input: %{body: "via-action-run"}},
                 tenant: "tenant-gateway",
                 actor: @actor
               )
               |> Ash.run_action()

      assert record.body == "via-action-run"
      assert record.tenant_id == "tenant-gateway"
    end
  end
end
