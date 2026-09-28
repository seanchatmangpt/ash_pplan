defmodule AshPPlan.FOND.Runtime.Idempotency do
 @moduledoc false
 def key(s,p,e),do: :crypto.hash(:sha256,:erlang.term_to_binary({s,p,e})) |> Base.encode16(case: :lower)
end
