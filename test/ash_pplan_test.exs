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
    assert AshPPlan.version() == "26.9.6"
  end

  test "public P-PLAN terms resolve to existing runtime owners" do
    assert %{target: "Reactor", status: "reuse"} =
             AshPPlan.projection("http://purl.org/net/p-plan#Plan")

    assert [%{target: "AshOban + Oban Cron", status: "reuse"}] =
             AshPPlan.projections_for(:temporal)
  end

  test "persistence remains an explicit admitted gap" do
    assert [%{status: "gap", owner: "consumer"}] = AshPPlan.projections_for(:persistence)
  end

  test "run/4 delegates execution to Reactor rather than creating a second executor" do
    assert {:ok, :hello} = AshPPlan.run(EchoReactor, %{value: :hello})
  end
end
