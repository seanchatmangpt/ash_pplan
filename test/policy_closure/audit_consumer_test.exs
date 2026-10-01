defmodule AshPPlan.PolicyClosure.AuditConsumerTest do
 use ExUnit.Case, async: true
 alias AshPPlan.PolicyClosure.AuditConsumer
 test "preserves evidence", do: assert AuditConsumer.project("s",[:e]).evidence==[:e]
end
