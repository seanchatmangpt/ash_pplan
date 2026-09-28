defmodule AshPPlan.PolicyClosure.MigrationTest do
 use ExUnit.Case, async: true
 alias AshPPlan.PolicyClosure.Migration
 test "preserves source", do: assert Migration.v1_to_v2(%{source_sha: "x"}).source_sha=="x"
end
