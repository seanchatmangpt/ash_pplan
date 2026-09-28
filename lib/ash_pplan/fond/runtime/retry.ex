defmodule AshPPlan.FOND.Runtime.Retry do
 @moduledoc false
 def allowed?(n,%AshPPlan.FOND.Runtime.Budget{retries:r}),do: n<r
end
