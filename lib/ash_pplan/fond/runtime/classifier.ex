defmodule AshPPlan.FOND.Runtime.Classifier do
 @moduledoc false
 def classify(:timeout),do: :edge
 def classify({:invalid,_}),do: :local
 def classify(_),do: :edge
end
