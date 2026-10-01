defmodule AshPPlan.FOND.Supervision.Admission do
  alias AshPPlan.FOND.Supervision.Validator

  def admit(domain, initial, candidates) do
    Enum.reduce(candidates, {[], []}, fn c, {ok, bad} ->
      case Validator.validate(domain, initial, c) do
        {:ok, v} -> {[v.candidate | ok], bad}
        {:error, e} -> {ok, [e | bad]}
      end
    end)
    |> then(fn {ok, bad} -> {Enum.reverse(ok), Enum.reverse(bad)} end)
  end
end
