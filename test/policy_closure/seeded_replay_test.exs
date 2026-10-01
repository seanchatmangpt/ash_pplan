defmodule AshPPlan.PolicyClosure.SeededReplayTest do
 use ExUnit.Case, async: true
 alias AshPPlan.PolicyClosure.SeededReplay
 test "seed retained", do: assert SeededReplay.bundle("s",42,[]).seed==42
end
