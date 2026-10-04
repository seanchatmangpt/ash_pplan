defmodule AshPPlan.Standing.ChainUnpairedCourtTest do
  @moduledoc """
  Court for `AshPPlan.Standing.Chain.unpaired/1`, the gate primitive behind the
  `:unpaired_pending` seal refusal (the refusal atom is covered in
  test/standing_test.exs; the primitive itself had no direct witness).
  Anti-vacuity: unpaired/1 must return [] on an empty and on a fully paired
  chain, must name open pendings by entry_id, and must pair outcomes by action —
  an outcome for one action leaves the other pendings open.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.Standing.Chain

  test "empty and fully paired chains have no unpaired entries" do
    assert Chain.unpaired([]) == []

    {:ok, chain} = Chain.append_pending([], "p1", "s", "act")
    refute Chain.unpaired(chain) == []

    {:ok, chain} = Chain.append_outcome(chain, "o1", "ALIVE", "s", "act")
    assert Chain.unpaired(chain) == []
  end

  test "open pendings are named by entry_id; outcomes pair by action, not by id" do
    {:ok, c0} = Chain.append_pending([], "p1", "s", "act")
    {:ok, c1} = Chain.append_pending(c0, "p2", "s", "act2")
    {:ok, c2} = Chain.append_pending(c1, "p3", "s", "act3")

    assert Chain.unpaired(c2) == ["p1", "p2", "p3"]

    # the outcome for act3 closes the pending whose action is act3 (p3);
    # the other pendings stay open regardless of their entry ids
    {:ok, c3} = Chain.append_outcome(c2, "o3", "ALIVE", "s", "act3")
    assert Chain.unpaired(c3) == ["p1", "p2"]

    {:ok, c4} = Chain.append_outcome(c3, "o1", "ALIVE", "s", "act")
    assert Chain.unpaired(c4) == ["p2"]

    # the drained set is exactly what sealing requires
    assert {:error, :unpaired_pending} = Chain.seal(c4, "seal", "ALIVE", "s")

    {:ok, c5} = Chain.append_outcome(c4, "o2", "ALIVE", "s", "act2")
    assert Chain.unpaired(c5) == []
    assert {:ok, _} = Chain.seal(c5, "seal", "ALIVE", "s")
  end
end
