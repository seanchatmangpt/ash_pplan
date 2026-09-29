defmodule AshPPlan.SA2A.Capability do
  @moduledoc """
  Planner capabilities exposed to the SA2A thin waist.

  These are construction capabilities only. They carry neither runtime
  authority nor DO standing.
  """

  @supported [:fond, :powl]

  def supported, do: @supported
  def supports?(formalism), do: formalism in @supported

  def descriptor(formalism) when formalism in @supported do
    %{
      formalism: formalism,
      authority: :none,
      standing: :candidate,
      select: true,
      construct: true,
      do: false
    }
  end
end
