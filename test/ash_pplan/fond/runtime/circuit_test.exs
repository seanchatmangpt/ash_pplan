defmodule AshPPlan.FOND.Runtime.CircuitTest do
 use ExUnit.Case, async: true
 alias AshPPlan.FOND.Runtime.Circuit
 test "opens at threshold" do c=%Circuit{threshold:2}|>Circuit.fail(); refute Circuit.open?(c); assert c|>Circuit.fail()|>Circuit.open?() end
end