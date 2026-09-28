defmodule AshPPlan.FOND.Runtime.State do
 @moduledoc false
 defstruct [:subject,:policy,:edge,failed: MapSet.new(),attempts: 0,status: :ready]
end
