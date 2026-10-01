defmodule AshPPlan.FOND.Supervision.ApplicationSupervisorTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Supervision.ApplicationSupervisor

  test "starts registry and dynamic supervisor" do
    {:ok, p} = ApplicationSupervisor.start_link()
    assert is_pid(Process.whereis(AshPPlan.FOND.Supervision.Registry))
    assert is_pid(Process.whereis(AshPPlan.FOND.Supervision.DynamicSupervisor))
    Supervisor.stop(p)
  end
end
