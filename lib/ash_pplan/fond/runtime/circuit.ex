defmodule AshPPlan.FOND.Runtime.Circuit do
 defstruct failures: 0, threshold: 3, opened_at: nil
 def fail(c) do n=c.failures+1; %{c|failures:n,opened_at:if(n>=c.threshold,do:System.monotonic_time(:millisecond),else:c.opened_at)} end
 def open?(c), do: not is_nil(c.opened_at)
 def reset(c), do: %{c|failures:0,opened_at:nil}
end