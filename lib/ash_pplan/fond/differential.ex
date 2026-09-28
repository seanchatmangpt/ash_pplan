defmodule AshPPlan.FOND.Differential do
  @moduledoc """
  Differential court joining the native FOND validator with an independent
  checker over the rendered TLA+ model.

  The checker is supplied by the caller. This module owns comparison semantics,
  not the external checker runtime.
  """

  alias AshPPlan.FOND
  alias AshPPlan.FOND.{Counterexample, Subject}

  @spec check(FOND.t(), FOND.policy(), FOND.state(), FOND.mode(), (map() -> map())) ::
          {:ok, map()} | {:error, map()}
  def check(%FOND{} = domain, policy, initial, mode, checker)
      when is_map(policy) and mode in [:strong, :strong_cyclic] and is_function(checker, 1) do
    subject = Subject.bind(domain, policy, initial, mode)
    validator = FOND.validate_policy(domain, policy, initial, mode)

    with {:ok, rendered} <- FOND.to_tla(domain, policy, initial, mode) do
      compare(subject, validator, checker.(rendered))
    end
  end

  @spec compare(map(), tuple(), map()) :: {:ok, map()} | {:error, map()}
  def compare(subject, validator, checker) do
    native = verdict(validator)
    independent = verdict(checker)

    if native == independent and native in [:admitted, :refused] do
      evidence =
        case {native, validator, checker} do
          {:refused, {:error, error}, _} ->
            [Counterexample.from_validator(subject, error), Counterexample.from_checker(subject, checker)]

          _ ->
            []
        end

      {:ok,
       %{
         schema: "ash_pplan/fond-differential/v1",
         subject_id: subject.id,
         verdict: native,
         agreement: true,
         native: validator,
         independent: checker,
         counterexamples: evidence
       }}
    else
      {:error,
       %{
         schema: "ash_pplan/fond-differential/v1",
         subject_id: subject.id,
         reason: :differential_mismatch,
         agreement: false,
         native_verdict: native,
         independent_verdict: independent,
         native: validator,
         independent: checker
       }}
    end
  end

  defp verdict({:ok, _}), do: :admitted
  defp verdict({:error, _}), do: :refused
  defp verdict(%{verdict: value}) when value in [:admitted, :refused], do: value
  defp verdict(_), do: :unknown
end
