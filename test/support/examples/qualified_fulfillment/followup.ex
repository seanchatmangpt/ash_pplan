defmodule AshPPlan.Examples.QualifiedFulfillment.Followup do
  @moduledoc """
  AshOban-based scheduling of `CheckDeliveryStatus` after shipment commit.

  The `DeliveryCheck` record carries the continuation reference (the
  `AshPPlan.Continuation` id of the durable run) so the deferred check is
  traceable to the run that committed the shipment. Job construction goes
  through `AshPPlan.Oban.construct_trigger/3`; AshOban/Oban keep delivery
  authority.
  """

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshPPlan.Examples.QualifiedFulfillment.Followup.DeliveryCheck
    end
  end

  defmodule DeliveryCheck do
    @moduledoc "Deferred delivery-status check carrying a continuation reference."
    use Ash.Resource,
      domain: AshPPlan.Examples.QualifiedFulfillment.Followup.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshOban]

    oban do
      domain AshPPlan.Examples.QualifiedFulfillment.Followup.Domain

      triggers do
        trigger :check_delivery_status do
          action :check_delivery_status
          where expr(checked != true)
          scheduler_cron false
          max_attempts 3
          worker_read_action :read

          worker_module_name AshPPlan.Examples.QualifiedFulfillment.Followup.CheckDeliveryStatusWorker
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

      update :check_delivery_status do
        change set_attribute(:checked, true)
      end
    end

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :continuation_ref, :string, allow_nil?: false, public?: true
      attribute :checked, :boolean, default: false, allow_nil?: false, public?: true
    end
  end

  @doc "Creates the deferred check record carrying the continuation reference."
  @spec record(String.t()) :: {:ok, struct()} | {:error, term()}
  def record(continuation_ref) do
    DeliveryCheck
    |> Ash.Changeset.for_create(:create, %{continuation_ref: continuation_ref}, domain: Domain)
    |> Ash.create()
  end

  @doc "Constructs (does not insert) the Oban job for `CheckDeliveryStatus`."
  @spec schedule(String.t()) :: {:ok, %{record: struct(), job: term()}} | {:error, term()}
  def schedule(continuation_ref) do
    with {:ok, record} <- record(continuation_ref),
         {:ok, job} <- AshPPlan.Oban.construct_trigger(record, :check_delivery_status) do
      {:ok, %{record: record, job: job}}
    end
  end
end
