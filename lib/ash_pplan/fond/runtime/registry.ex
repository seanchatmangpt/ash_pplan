defmodule AshPPlan.FOND.Runtime.Registry do
 @moduledoc false
 def new,do: %{}
 def put(r,id,p),do: Map.put(r,id,p)
 def get(r,id),do: Map.fetch(r,id)
end
