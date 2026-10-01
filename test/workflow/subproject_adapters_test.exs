defmodule AshPPlan.SubprojectAdaptersTest do
  @moduledoc """
  Court for the subproject adapters after the durable engine replaced the third-party ones.

  bb_reactor still resolves every op to a loadable `Reactor.Step` or a typed unsupported error.
  The retired `ash_durable_reactor` and `ash_oban` adapters are gone from the table, and the
  capabilities they served (human approval, deferred scheduling) resolve through the native
  `durable` adapter. Mutations: an absent implementation and an unknown op are typed unsupported
  rather than crashing; a retired adapter id is refused rather than silently routed.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.{Realization, Reactor}
  alias AshPPlan.Reactor.Adapters.Durable

  defp real(adapter, op, options \\ []) do
    %Realization{
      capability: "X.Y",
      provider: :t,
      binding: %{adapter: adapter, op: op},
      options: options
    }
  end

  test "live adapters are registered and allowlisted" do
    for id <- ~w(bb_reactor durable local)a do
      assert Map.has_key?(Reactor.adapters(), id)
      assert id in Realization.adapters()
    end
  end

  test "retired adapters are gone from the table" do
    for id <- ~w(ash_durable_reactor ash_oban)a do
      refute Map.has_key?(Reactor.adapters(), id)
      refute id in Realization.adapters()
    end

    refute Code.ensure_loaded?(AshPPlan.Reactor.Adapters.AshDurableReactor)
    refute Code.ensure_loaded?(AshPPlan.Reactor.Adapters.AshOban)
    refute Code.ensure_loaded?(AshPPlan.Continuation)
  end

  test "every op resolves to a loadable Reactor.Step" do
    for id <- ~w(bb_reactor durable)a,
        mod = Reactor.adapters()[id],
        mod.available?(),
        op <- mod.ops() do
      assert {:ok, {step, _kw}} = Reactor.step_for(real(id, op)), "#{id}/#{op}"
      assert :ok = Reactor.validate_step(step)
    end
  end

  test "capability ops map as specified" do
    assert Realization.op_for("Actuator.Command") in Reactor.adapters()[:bb_reactor].ops()
    assert Realization.op_for("State.Await") in Reactor.adapters()[:bb_reactor].ops()
    assert Realization.op_for("Human.Approve") in Durable.ops()
    assert Realization.op_for("Schedule.Deferred") in Durable.ops()
  end

  test "mutation: absent implementation and unknown ops are typed unsupported" do
    for id <- ~w(bb_reactor)a do
      op = hd(Reactor.adapters()[id].ops())

      assert {:error, %{reason: :unsupported, adapter: ^id, detail: :implementation_unavailable}} =
               Reactor.step_for(real(id, op, available?: false))

      assert {:error, %{reason: :unsupported, adapter: ^id, detail: {:unknown_op, :nope}}} =
               Reactor.step_for(real(id, :nope))
    end

    assert {:error, %{reason: :unsupported, adapter: :durable, detail: {:unknown_op, :nope}}} =
             Reactor.step_for(real(:durable, :nope))
  end

  test "mutation: a retired adapter id is refused, not routed" do
    for id <- ~w(ash_durable_reactor ash_oban)a do
      assert {:error, _} = Reactor.step_for(real(id, :human_approve))
    end
  end
end
