defmodule AshPPlan.FOND.Supervision.Reselector do
  alias AshPPlan.FOND.Supervision.{Admission,ExclusionSet,Preference}
  def select(domain,initial,candidates,excluded) do
    {ok,bad}=candidates |> ExclusionSet.filter(excluded) |> then(&Admission.admit(domain,initial,&1))
    case Preference.choose(ok) do {:ok,c}->{:ok,c,bad}; {:error,r}->{:error,r,bad} end
  end
end
