defmodule AshPPlan.PolicyClosure.SeededReplay do
  def bundle(subject_id, seed, observations),
    do: %{subject_id: subject_id, seed: seed, observations: observations}
end
