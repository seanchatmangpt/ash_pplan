defmodule AshPPlan.PolicyClosure.ObservationTest do
  use ExUnit.Case, async: true
  alias AshPPlan.PolicyClosure.Observation
  test "subject bound", do: assert(Observation.new("s", :outcome, :ok).subject_id == "s")
end
