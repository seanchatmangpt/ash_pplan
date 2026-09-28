defmodule AshPPlan.FOND.Runtime.Status do
 @moduledoc false
 def terminal?(:succeeded),do: true
 def terminal?(:exhausted),do: true
 def terminal?(_),do: false
end
