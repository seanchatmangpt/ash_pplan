defmodule AshPPlan.FOND.Runtime.Capability do
  @moduledoc false
  defstruct [:name, constraints: %{}]
  def satisfied?(%__MODULE__{name: n}, caps), do: n in caps
end
