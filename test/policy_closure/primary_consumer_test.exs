defmodule AshPPlan.PolicyClosure.PrimaryConsumerTest do
 use ExUnit.Case, async: true
 alias AshPPlan.PolicyClosure.PrimaryConsumer
 test "authority free", do: assert PrimaryConsumer.project("s",%{}).authority==:none
end
