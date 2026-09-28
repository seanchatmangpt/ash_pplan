defmodule AshPPlan.FONDFixtureContractTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Differential
  alias AshPPlan.Test.{FONDFixture, TLAReader}

  test "committed fixture corpus is executable and falsifier-bearing" do
    fixtures = FONDFixture.all()
    assert length(fixtures) >= 10

    for fixture <- fixtures do
      assert is_binary(fixture.falsifier) and fixture.falsifier != ""
      {:ok, domain} = FOND.new(fixture.transitions, fixture.goals)

      assert {:ok, report} =
               Differential.check(
                 domain,
                 fixture.policy,
                 fixture.initial,
                 fixture.mode,
                 &TLAReader.check!/1
               ),
             fixture.name

      assert report.verdict == fixture.expected, fixture.name

      if fixture.failure_class do
        assert Enum.any?(report.counterexamples, &(&1.class == fixture.failure_class)),
               fixture.name
      end
    end
  end
end
