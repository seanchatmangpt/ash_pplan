defmodule AshPPlan.FOND.Runtime.Run do
 @moduledoc false
 defstruct [:id,:subject,:policy,status: :ready,failed: MapSet.new(),receipts: []]
end
