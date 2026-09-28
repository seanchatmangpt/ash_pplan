defmodule AshPPlan.FOND.Runtime.TransitionTest do
 use ExUnit.Case, async: true
 alias AshPPlan.FOND.Runtime.Transition
 test "rejects impossible terminal transition" do assert {:error,_}=Transition.admit(:succeeded,:running) end
 test "admits recovery", do: assert Transition.admit(:running,:recovering)==:ok
end