defmodule AshPPlan.FOND.Runtime.Outcome do
 def classify({:ok,_}=x), do: x
 def classify({:error,r}) when r in [:timeout,:unavailable], do: {:retryable,r}
 def classify({:error,:refused}), do: {:refused,:refused}
 def classify({:error,r}), do: {:terminal,r}
end