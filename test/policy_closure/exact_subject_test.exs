defmodule AshPPlan.PolicyClosure.ExactSubjectTest do
  use ExUnit.Case, async: true
  alias AshPPlan.PolicyClosure.ExactSubject
  test "binds exact coordinates", do: assert(ExactSubject.bind(:p, :q, :s, "a").source_sha == "a")
end
