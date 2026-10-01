defmodule AshPPlan.PolicyClosure.SimulationConsumerTest do
 use ExUnit.Case, async: true
 alias AshPPlan.PolicyClosure.SimulationConsumer
 test "simulation only", do: assert SimulationConsumer.project("s",[]).consumer==:simulation
end
