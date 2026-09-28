defmodule AshPPlan.FOND.Runtime.DeadlineTest do
 use ExUnit.Case, async: true
 alias AshPPlan.FOND.Runtime.Deadline
 test "remaining never negative" do assert Deadline.remaining(Deadline.new(10))>=0 end
end