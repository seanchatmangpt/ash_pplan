defmodule AshPPlan.FOND.Runtime.Dispatch do
 @moduledoc false
 def next(edges,failed),do: case AshPPlan.FOND.Runtime.Router.route(edges,failed) do nil->{:error,:exhausted}; e->{:ok,e} end
end
