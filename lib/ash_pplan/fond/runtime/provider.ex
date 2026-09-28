defmodule AshPPlan.FOND.Runtime.Provider do
 @moduledoc false
 @callback capabilities(term()) :: [atom()]
 @callback invoke(term(),term()) :: {:ok,term()}|{:error,term()}
end
