defmodule AshPPlan.PolicyClosure.EvidenceTest do
 use ExUnit.Case, async: true
 alias AshPPlan.PolicyClosure.Evidence
 test "rejects adjacent subject", do: assert {:error,:subject_mismatch}=Evidence.admit("a",%{subject_id: "b"})
end
