defmodule AshPPlan.PolicyClosure.ProvenanceTest do
 use ExUnit.Case, async: true
 alias AshPPlan.PolicyClosure.Provenance
 test "pins sha", do: assert Provenance.bind("a",:fond,:compiler).source_sha=="a"
end
