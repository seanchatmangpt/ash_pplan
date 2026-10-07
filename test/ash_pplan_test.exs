defmodule AshPPlanTest do
  use ExUnit.Case, async: true

  defmodule EchoReactor do
    use Reactor

    input(:value)

    step :echo do
      argument(:value, input(:value))
      run(fn %{value: value}, _context -> {:ok, value} end)
    end

    return(:echo)
  end

  test "reports the release version" do
    assert AshPPlan.version() == "26.10.7"
  end

  test "public P-PLAN terms resolve to existing runtime owners" do
    assert %{target: "Reactor", status: "reuse"} =
             AshPPlan.projection("http://purl.org/net/p-plan#Plan")

    assert [%{target: "AshPPlan.Reactor.Durable", owner: "durable", status: "reuse"}] =
             AshPPlan.projections_for(:temporal)
  end

  test "semantic execution and evidence are admitted extensions" do
    assert [%{status: "extension", owner: "ash_pplan"}] =
             AshPPlan.projections_for(:execution)

    assert [%{status: "extension", owner: "ash_pplan"}] =
             AshPPlan.projections_for(:evidence)
  end

  test "persistence is the durable ledger checkpoint store, not a consumer gap" do
    assert [%{status: "reuse", owner: "durable", primitive: "durable ledger checkpoint store"}] =
             AshPPlan.projections_for(:persistence)
  end

  test "run/4 delegates execution to Reactor rather than creating a second executor" do
    assert {:ok, :hello} = AshPPlan.run(EchoReactor, %{value: :hello})
  end
end
