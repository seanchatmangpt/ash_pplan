defmodule AshPPlan.FOND.Runtime.Circuit do
 @moduledoc false
 defstruct failures: 0,threshold: 3,state: :closed
 def fail(c) do n=c.failures+1; %{c|failures:n,state:if(n>=c.threshold,do: :open,else:c.state)} end
end
