defmodule AshPPlan.FOND.Supervision.ProviderResult do
  def normalize(p,{:ok,c}) when is_list(c), do: {:ok,p,c}
  def normalize(p,{:error,r}), do: {:error,p,r}
  def normalize(p,x), do: {:error,p,{:invalid_provider_result,x}}
end
