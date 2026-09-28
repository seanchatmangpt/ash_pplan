defmodule AshPPlan.FOND.Runtime.Lease do
 defstruct [:owner,:expires_at]
 def new(o,ms), do: %__MODULE__{owner:o,expires_at:System.monotonic_time(:millisecond)+ms}
 def valid?(l), do: l.expires_at>System.monotonic_time(:millisecond)
end