defmodule AshPPlan.FOND.Supervision.Outcome do
  @enforce_keys [:candidate_id, :state, :observed]
  defstruct [:candidate_id, :state, :observed, :at]

  def new(id, state, observed),
    do: %__MODULE__{
      candidate_id: id,
      state: state,
      observed: observed,
      at: System.system_time(:millisecond)
    }
end
