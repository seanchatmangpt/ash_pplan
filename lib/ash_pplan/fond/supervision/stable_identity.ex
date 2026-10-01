defmodule AshPPlan.FOND.Supervision.StableIdentity do
  def of(policy, semantics),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary({semantics, policy}, [:deterministic]))
      |> Base.encode16(case: :lower)
end
