defmodule AshPPlan.FOND.Runtime.Queue do
 @moduledoc false
 def new,do: :queue.new()
 def push(q,x),do: :queue.in(x,q)
 def pop(q),do: :queue.out(q)
end
