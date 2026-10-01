defmodule AshPPlan.DescriptorFixtures.Domain do
  @moduledoc false

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshPPlan.DescriptorFixtures.PlainResource
    resource AshPPlan.DescriptorFixtures.MinimalLifecycle
    resource AshPPlan.DescriptorFixtures.ConfiguredLifecycle
    resource AshPPlan.DescriptorFixtures.PolicyGuardedLifecycle
  end
end

defmodule AshPPlan.DescriptorFixtures.PlainResource do
  @moduledoc "Ash resource with neither AshStateMachine nor AshOban."

  use Ash.Resource,
    domain: AshPPlan.DescriptorFixtures.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    default_accept :*
    defaults [:read, :create]
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshPPlan.DescriptorFixtures.MinimalLifecycle do
  @moduledoc """
  AshStateMachine resource with one concrete transition and nothing optional:
  no `action: :*`, no policies, no `next_state`, no upsert transition. It also
  declares an update action literally named `:all` that has no transition.
  """

  use Ash.Resource,
    domain: AshPPlan.DescriptorFixtures.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStateMachine]

  state_machine do
    initial_states [:draft]
    # ash_state_machine 0.2.13 does not guarantee `default_initial_state` is
    # back-propagated onto the `state` attribute: its `SetDefaultInitialState`
    # transformer declares no before?/after? constraints, so Spark's
    # `Transformer.sort/1` may emit `AddState` first, compiling `state` with
    # `default: nil` (creates then fail "attribute state is required").
    # Declaring it explicitly is compile-verified by `AddState`.
    default_initial_state :draft

    transitions do
      transition :publish, from: :draft, to: :published
    end
  end

  actions do
    default_accept :*
    defaults [:read, :create]

    update :publish do
      change transition_state(:published)
    end

    update :all
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshPPlan.DescriptorFixtures.ConfiguredLifecycle do
  @moduledoc """
  AshStateMachine resource that configures the optional lifecycle surfaces that
  compile without a SAT solver: `next_state`, an upsert create transition and an
  `action: :*` transition. `:legacy` is deprecated but explicitly referenced by
  a transition, so AshStateMachine keeps it in the wildcard universe.
  `PolicyGuardedLifecycle` covers the `ValidNextState` policy preflight.
  """

  use Ash.Resource,
    domain: AshPPlan.DescriptorFixtures.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStateMachine]

  state_machine do
    initial_states [:pending]
    default_initial_state :pending
    deprecated_states [:legacy]

    transitions do
      transition :advance, from: :pending, to: :complete
      transition :restore, from: :legacy, to: :pending
      transition :upsert_pending, from: :*, to: :pending
      transition :*, from: :complete, to: :archived
    end
  end

  actions do
    default_accept :*
    defaults [:read]

    create :upsert_pending do
      upsert? true
      change transition_state(:pending)
    end

    update :advance do
      require_atomic? false
      change next_state()
    end

    update :archive do
      change transition_state(:archived)
    end

    update :restore do
      change transition_state(:pending)
    end
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshPPlan.DescriptorFixtures.EmptyOban do
  @moduledoc "AshOban installed with no triggers and no scheduled actions."

  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshOban]

  oban do
    domain AshPPlan.DescriptorFixtures.Domain
  end

  actions do
    defaults [:read]
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshPPlan.DescriptorFixtures.ScheduleOnlyOban do
  @moduledoc "AshOban resource with one scheduled action and no triggers."

  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshOban]

  oban do
    domain AshPPlan.DescriptorFixtures.Domain

    scheduled_actions do
      schedule :tick, "0 * * * *" do
        action :tick
        list_tenants [nil]
        worker_module_name AshPPlan.DescriptorFixtures.ScheduleOnlyOban.TickWorker
      end
    end
  end

  actions do
    defaults [:read]
    create :tick
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshPPlan.DescriptorFixtures.SectionTenantsOban do
  @moduledoc """
  AshOban resource whose tenant list and default actor come from resolved
  configuration: `list_tenants` is set only in the `oban` section, which AshOban
  applies to the trigger at job runtime.
  """

  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshOban]

  oban do
    domain AshPPlan.DescriptorFixtures.Domain
    list_tenants ["tenant_a", "tenant_b"]

    triggers do
      trigger :process do
        action :process
        scheduler_cron false
        default_actor :system
        worker_read_action :read
        worker_module_name AshPPlan.DescriptorFixtures.SectionTenantsOban.ProcessWorker
      end
    end
  end

  actions do
    default_accept :*
    defaults [:create]

    read :read do
      primary? true
      pagination keyset?: true
    end

    update :process
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshPPlan.DescriptorFixtures.DeletedTriggerOban do
  @moduledoc """
  AshOban resource whose only trigger is `state :deleted`. AshOban cancels
  every job of such a trigger, so it must not count as a live capability.
  """

  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshOban]

  oban do
    domain AshPPlan.DescriptorFixtures.Domain

    triggers do
      trigger :retire do
        action :retire
        state :deleted
        max_attempts 5
        worker_read_action :read
        worker_module_name AshPPlan.DescriptorFixtures.DeletedTriggerOban.RetireWorker
        scheduler_module_name AshPPlan.DescriptorFixtures.DeletedTriggerOban.RetireScheduler
      end
    end
  end

  actions do
    default_accept :*
    defaults [:create]

    read :read do
      primary? true
      pagination keyset?: true
    end

    update :retire
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshPPlan.DescriptorFixtures.TenantFromRecordOban do
  @moduledoc "AshOban trigger that takes its tenant from the record."

  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshOban]

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  oban do
    domain AshPPlan.DescriptorFixtures.Domain

    triggers do
      trigger :process do
        action :process
        scheduler_cron false
        use_tenant_from_record? true
        worker_read_action :read
        worker_module_name AshPPlan.DescriptorFixtures.TenantFromRecordOban.ProcessWorker
      end
    end
  end

  actions do
    default_accept :*
    defaults [:create]

    read :read do
      primary? true
      pagination keyset?: true
    end

    update :process
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :org_id, :string, public?: true
  end
end

defmodule AshPPlan.DescriptorFixtures.PolicyGuardedLifecycle do
  @moduledoc """
  AshStateMachine resource whose policies use `AshStateMachine.Checks.ValidNextState`,
  the only configuration that makes `policy_preflight?` a resource fact.
  (`Ash.Policy.Authorizer` needs a SAT solver, so `simple_sat` is a test dependency.)
  """

  use Ash.Resource,
    domain: AshPPlan.DescriptorFixtures.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  state_machine do
    initial_states [:draft]
    # Same ash_state_machine 0.2.13 transformer-ordering contract as
    # MinimalLifecycle: without an explicit default the compiled `state`
    # attribute can end up with `default: nil`.
    default_initial_state :draft

    transitions do
      transition :publish, from: :draft, to: :published
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type(:update) do
      authorize_if AshStateMachine.Checks.ValidNextState
    end
  end

  actions do
    default_accept :*
    defaults [:read, :create]

    update :publish do
      change transition_state(:published)
    end
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end
end
