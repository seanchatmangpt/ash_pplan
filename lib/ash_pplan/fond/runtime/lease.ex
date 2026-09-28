defmodule AshPPlan.FOND.Runtime.Lease do
 @moduledoc false
 defstruct [:key,:owner,:expires_at]
 def valid?(%__MODULE__{expires_at:e},now),do: e>now
end
