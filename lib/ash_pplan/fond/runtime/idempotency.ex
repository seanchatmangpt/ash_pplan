defmodule AshPPlan.FOND.Runtime.Idempotency do
  def key(c, i),
    do: :crypto.hash(:sha256, :erlang.term_to_binary({c, i})) |> Base.encode16(case: :lower)
end
