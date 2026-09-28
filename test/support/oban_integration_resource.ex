defmodule AshPPlan.ObanIntegrationDomain do
  @moduledoc false

  use Ash.Domain, validate_config_inclusion?: false
end

defmodule AshPPlan.ObanIntegrationResource do
  @moduledoc """
  Shared AshStateMachine/AshOban fixture resource for `AshPPlan.ObanTest`.

  Lives under `test/support` so it is compiled before protocol consolidation
  instead of being defined while the test file is loaded.
  """

  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshOban]

  oban do
    domain AshPPlan.ObanIntegrationDomain
    shared_context [:job]

    triggers do
      trigger :process do
        action :process
        where expr(processed != true)
        scheduler_cron false
        max_attempts 3
        backoff 15
        worker_read_action :read
        worker_module_name AshPPlan.ObanIntegrationResource.ProcessWorker
      end
    end

    scheduled_actions do
      schedule :tick, "0 * * * *" do
        action :tick
        worker_module_name AshPPlan.ObanIntegrationResource.TickWorker
      end
    end
  end

  actions do
    default_accept :*

    read :read do
      primary? true
      pagination keyset?: true
    end

    create :tick

    update :process do
      change set_attribute(:processed, true)
    end
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :processed, :boolean, default: false, allow_nil?: false
  end
end
