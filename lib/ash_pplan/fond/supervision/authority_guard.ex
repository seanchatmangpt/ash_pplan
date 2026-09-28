defmodule AshPPlan.FOND.Supervision.AuthorityGuard do
  @forbidden [:authority,:do,:actuate,:standing,:token,:credential]
  def check(metadata) when is_map(metadata), do: case Enum.find(@forbidden,&Map.has_key?(metadata,&1)) do nil->:ok; key->{:error,{:authority_bearing_policy,key}} end
  def check(_), do: {:error,:invalid_metadata}
end
