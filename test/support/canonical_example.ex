defmodule AshPPlan.Test.CanonicalExample do
  @moduledoc """
  THE canonical pplan example: the QualifiedFulfillment durable spine
  (`admit_order -> authorize_payment -> await_human_release -> commit_shipment`) run on the real
  durable engine. Every moonshot-capability court validates against THIS one example, so a
  capability regression shows up as the same example failing in a new place.

  Chicago-school: everything real — real engine, real stores, real signals, real effect counters.
  `run/2` drives one completion (start, park at the release gate, signal approval, converge) on the
  given store pid and returns:

      %{id:, store:, store_mod:, record:, tape: [labels], counts: %{admit: n, ...}}
  """

  alias AshPPlan.Reactor.Durable.Engine
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.{DurableFx, Effects}

  @id "canonical-1"

  def id, do: @id
  def signal_name, do: DurableFx.signal_name()

  @doc "Model + bindings + inputs; the attrs map consumed by `Engine.start/3`."
  def attrs(id \\ @id, opts \\ []), do: DurableFx.attrs(id, opts)

  def model, do: DurableFx.model()

  @doc "Drive one canonical completion on `store_pid` (Store.Ets or Store.Dets pid)."
  @spec run(pid(), keyword()) :: %{
          id: String.t(),
          store: pid(),
          store_mod: module(),
          record: AshPPlan.Reactor.Durable.Record.t(),
          tape: [String.t()],
          counts: map()
        }
  def run(store_pid, opts \\ []) do
    store_mod = opts[:store_mod] || Ets
    id = opts[:id] || @id

    {:ok, _} = Engine.start(store_pid, DurableFx.attrs(id, opts))

    {:parked, :waiting} = Engine.attempt(store_pid, id, store_module: store_mod)

    {:ok, _sig} = Engine.signal(store_pid, id, DurableFx.signal_name(), :approved)
    {:completed, _result} = Engine.attempt(store_pid, id, store_module: store_mod)

    %{
      id: id,
      store: store_pid,
      store_mod: store_mod,
      record: Engine.fetch(store_pid, id, store_module: store_mod),
      tape: Enum.map(Engine.steps(store_pid, id, store_module: store_mod), & &1.label),
      counts: Effects.all(opts[:effects] || default_effects())
    }
  end

  defp default_effects,
    do: Application.get_env(:ash_pplan, :canonical_effects, AshPPlan.Test.Effects)
end
