defmodule AshPPlan.FOND.SupervisionSession do
  @moduledoc "Provider registry and reselection state machine around PolicySupervisor."
  alias AshPPlan.FOND.PolicySupervisor

  defstruct [:supervisor, offers: [], provider_status: %{}]

  def new(supervisor, offers) do
    providers = Map.new(supervisor.providers, &{&1, :up})
    %__MODULE__{supervisor: supervisor, offers: offers, provider_status: providers}
  end

  def select(%__MODULE__{}=s) do
    live = Enum.filter(s.offers, &(Map.get(s.provider_status, &1.provider) == :up))
    case PolicySupervisor.select(s.supervisor, live) do
      {:ok, sup, receipt} -> {:ok, %{s|supervisor: sup}, receipt}
      error -> error
    end
  end

  def provider_down(%__MODULE__{}=s, provider) do
    sup = PolicySupervisor.provider_down(s.supervisor, provider)
    %{s | supervisor: sup, provider_status: Map.put(s.provider_status, provider, :down)}
  end

  def provider_up(%__MODULE__{}=s, provider) do
    sup = %{s.supervisor | providers: Enum.uniq([provider|s.supervisor.providers]), epoch: s.supervisor.epoch + 1}
    %{s | supervisor: sup, provider_status: Map.put(s.provider_status, provider, :up)}
  end

  def observe(%__MODULE__{}=s, action, outcome, epoch) do
    case PolicySupervisor.observe(s.supervisor, action, outcome, epoch) do
      {:ok, sup, receipt} -> {:ok, %{s|supervisor: sup}, receipt}
      error -> error
    end
  end

  def next_intent(%__MODULE__{}=s), do: PolicySupervisor.construct(s.supervisor)

  def ocel_event(kind, receipt) do
    %{type: "fond_" <> Atom.to_string(kind), time: DateTime.utc_now() |> DateTime.to_iso8601(),
      attributes: %{epoch: receipt.epoch, state: inspect(receipt.state), digest: receipt.digest}}
  end
end
