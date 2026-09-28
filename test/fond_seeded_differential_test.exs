defmodule AshPPlan.FONDSeededDifferentialTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.{Corpus, Differential}
  alias AshPPlan.Test.TLAReader

  test "seeded corpus preserves native/reader agreement in both modes" do
    for item <- Corpus.seeded(120, {17, 31, 53}),
        mode <- [:strong, :strong_cyclic] do
      {:ok, domain} = FOND.new(item.transitions, item.goals)

      assert {:ok, report} =
               Differential.check(
                 domain,
                 item.policy,
                 item.initial,
                 mode,
                 &TLAReader.check!/1
               ),
             inspect(%{item: item.id, mode: mode})

      assert report.agreement
    end
  end
end
