defmodule AshPPlan.FOND.Runtime.Provider do
 @callback capabilities(term()) :: [atom()]
 @callback dispatch(term(),term(),keyword()) :: {:ok,term()}|{:error,term()}
end