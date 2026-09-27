defmodule AshPPlan.FOND.PolicySupervisorTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.PolicySupervisor
  alias AshPPlan.FOND.SupervisionSession

  setup do
    {:ok, domain}=AshPPlan.fond_domain(%{pending: %{attempt: [:pending,:done]}, done: %{}}, [:done])
    strong=%{pending: :attempt}
    sup=PolicySupervisor.new(domain,:pending,[:a,:b])
    %{domain: domain, strong: strong, sup: sup}
  end

  test "prefers strong then stable provider and constructs no DO authority", c do
    offers=[%{provider: :b,policy:c.strong,mode: :strong_cyclic,cost: 0},
            %{provider: :a,policy:c.strong,mode: :strong,cost: 9}]
    assert {:ok,s,_}=PolicySupervisor.select(c.sup,offers)
    assert {:ok,%{provider: :a,authority: :none,do: false}}=PolicySupervisor.construct(s)
  end

  test "refuses authority-bearing offers", c do
    assert {:error,%{reason: :no_admissible_policy}}=
      PolicySupervisor.select(c.sup,[%{provider: :a,policy:c.strong,mode: :strong,authority: :do}])
  end

  test "provider loss fences epoch and permits fallback", c do
    offers=[%{provider: :a,policy:c.strong,mode: :strong},%{provider: :b,policy:c.strong,mode: :strong}]
    session=SupervisionSession.new(c.sup,offers)
    {:ok,session,_}=SupervisionSession.select(session)
    old=session.supervisor.epoch
    session=SupervisionSession.provider_down(session,:a)
    assert {:error,%{reason: :stale_epoch}}=SupervisionSession.observe(session,:attempt,:done,old)
    assert {:ok,session,_}=SupervisionSession.select(session)
    assert session.supervisor.selection.provider == :b
  end
end
