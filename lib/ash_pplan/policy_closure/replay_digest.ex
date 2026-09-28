defmodule AshPPlan.PolicyClosure.ReplayDigest do
 def digest(term), do: :crypto.hash(:sha256,:erlang.term_to_binary(term,[:deterministic])) |> Base.encode16(case: :lower)
end
