defmodule AshPPlan.ProcessEvidence.Event do
  @moduledoc "One process-evidence event: activity over qualified objects, bound to a subject."
  @enforce_keys [:id, :activity, :timestamp]
  defstruct id: nil,
            activity: nil,
            timestamp: nil,
            objects: [],
            attributes: %{},
            subject_id: nil

  @type object :: {String.t(), String.t(), String.t()}
  @type t :: %__MODULE__{
          id: String.t(),
          activity: String.t(),
          timestamp: DateTime.t(),
          objects: [object()],
          attributes: map(),
          subject_id: String.t() | nil
        }
end
