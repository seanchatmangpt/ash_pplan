defmodule AshPPlan.PolicyClosure.CheckpointTest do
  use ExUnit.Case, async: true
  alias AshPPlan.PolicyClosure.Checkpoint
  test "ordered", do: assert(Checkpoint.new("s", "p", 3).ordinal == 3)
end
