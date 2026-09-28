defmodule AshPPlan.FOND.Runtime.Health do
 @moduledoc false
 defstruct status: :unknown,failures: 0,successes: 0
 def fail(h),do: %{h|status: :degraded,failures:h.failures+1}
end
