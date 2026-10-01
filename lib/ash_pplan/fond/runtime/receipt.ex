defmodule AshPPlan.FOND.Runtime.Receipt do
  @enforce_keys [:run_id, :capability, :status]
  defstruct [:run_id, :capability, :status, :attempts, :failures, :result]

  def from_state(id, s),
    do: %__MODULE__{
      run_id: id,
      capability: s.capability,
      status: s.status,
      attempts: s.attempts,
      failures: Enum.reverse(s.failures),
      result: s.result
    }
end
