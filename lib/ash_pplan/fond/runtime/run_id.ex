defmodule AshPPlan.FOND.Runtime.RunId do
 @moduledoc false
 def new(prefix \\ "fond"),do: prefix<>"-"<>Base.encode16(:crypto.strong_rand_bytes(8),case: :lower)
end
