defmodule AshPPlan.FOND.Runtime do
  @moduledoc "OTP owner that serializes fenced FOND supervision transitions without executing provider work."
  use GenServer
  alias AshPPlan.FOND.SupervisionSession

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end
  def intent(server), do: GenServer.call(server, :intent)
  def snapshot(server), do: GenServer.call(server, :snapshot)
  def observe_outcome(server, epoch, outcome), do: GenServer.call(server, {:outcome, epoch, outcome})
  def observe_provider_health(server, generation, id, healthy?), do: GenServer.call(server, {:provider_health, generation, id, healthy?})
  def replace_registry(server, registry), do: GenServer.call(server, {:replace_registry, registry})

  @impl true
  def init(opts) do
    case SupervisionSession.start(Keyword.fetch!(opts, :policy), Keyword.fetch!(opts, :registry), Keyword.get(opts, :requirements, [])) do
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:intent, _from, session), do: {:reply, SupervisionSession.intent(session), session}
  def handle_call(:snapshot, _from, session), do: {:reply, session, session}
  def handle_call({:outcome, epoch, outcome}, _from, session), do: transition(session, SupervisionSession.observe_outcome(session, epoch, outcome))
  def handle_call({:provider_health, generation, id, healthy?}, _from, session), do: transition(session, SupervisionSession.observe_provider_health(session, generation, id, healthy?))
  def handle_call({:replace_registry, registry}, _from, session), do: transition(session, SupervisionSession.replace_registry(session, registry))
  defp transition(_old, {:ok, next}), do: {:reply, {:ok, next}, next}
  defp transition(old, {:error, reason}), do: {:reply, {:error, reason}, old}
end
