defmodule AshPPlan.FOND.Runtime.Budget do
  @moduledoc false
  defstruct attempts: 8, retries: 3, timeout_ms: 30_000
end
