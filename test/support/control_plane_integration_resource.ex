defmodule AshPPlan.ControlPlaneIntegrationDomain do
  @moduledoc false

  use Ash.Domain, validate_config_inclusion?: false
end

defmodule AshPPlan.ControlPlaneIntegrationResource do
  @moduledoc """
  Shared AshStateMachine/AshOban fixture resource for `AshPPlan.ControlPlaneTest`.

  Lives under `test/support` so it is compiled before protocol consolidation
  instead of being defined while the test file is loaded.
  """

  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStateMachine, AshOban]

  state_machine do
    initial_states [:pending]

    transitions do
      transition :process, from: :pending, to: :complete
    end
  end

  oban do
    domain AshPPlan.ControlPlaneIntegrationDomain

    triggers do
      trigger :process do
        action :process
        where expr(state == :pending)
        scheduler_cron false
        max_attempts 4
        worker_read_action :read
        worker_module_name AshPPlan.ControlPlaneIntegrationResource.ProcessWorker
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

    update :process do
      change transition_state(:complete)
    end
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end
end
