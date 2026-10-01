defmodule AshPPlan.FOND.Runtime.PolicyId do
  @moduledoc false
  def of(p), do: :crypto.hash(:sha256, :erlang.term_to_binary(p)) |> Base.encode16(case: :lower)
end
