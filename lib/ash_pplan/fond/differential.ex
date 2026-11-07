defmodule AshPPlan.FOND.Differential do
  @moduledoc """
  Differential court joining the native FOND validator with an independent
  checker over the rendered TLA+ model.

  The checker is supplied by the caller. This module owns comparison semantics,
  not the external checker runtime.

  Agreement is verdict-level AND reason-level: `admitted/admitted` agrees, and
  `refused/refused` agrees only when both sides name the SAME error reason
  (the validator's `:reason` / the checker's `:kind` or `:reason`). Two
  refusals with different reasons are a `:differential_mismatch` — a court
  that agrees on "refused" but not on WHY is not agreement.
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

    if agree?(native, reason(validator), independent, reason(checker)) do
      evidence =
        case {native, validator, checker} do
          {:refused, {:error, error}, _} ->
            [
              Counterexample.from_validator(subject, error),
              Counterexample.from_checker(subject, checker)
            ]

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

  # Agreement is verdict-level AND reason-level. `admitted/admitted` agrees
  # outright; `refused/refused` agrees only when both sides name the same
  # error reason up to `Counterexample.classify/1` — the shared equivalence
  # the court already uses to normalize the validator's `:reason` vocabulary
  # (`:not_strong`, `:missing_policy_action`, ...) and the checker's `:kind`
  # vocabulary (`:liveness`, `:deadlock`) onto one class set. Two refusals
  # whose classes differ disagree on WHY and stay a typed mismatch; an
  # untyped refusal (`nil` reason) never agrees with a typed one.
  defp agree?(:refused, reason, :refused, reason) when not is_nil(reason), do: true
  defp agree?(:refused, native, :refused, independent)
       when not is_nil(native) and not is_nil(independent) do
    Counterexample.classify(native) == Counterexample.classify(independent)
  end

  defp agree?(:admitted, _native_reason, :admitted, _independent_reason), do: true
  defp agree?(_, _, _, _), do: false

  defp verdict({:ok, _}), do: :admitted
  defp verdict({:error, _}), do: :refused
  defp verdict(%{verdict: value}) when value in [:admitted, :refused], do: value
  defp verdict(_), do: :unknown

  # The refusal reason each side names: the validator's `:reason`, or the
  # checker's `:kind` (fallback `:reason`). `nil` when the side did not refuse
  # with a typed reason.
  defp reason({:error, %{reason: reason}}), do: reason
  defp reason(%{verdict: :refused, kind: kind}), do: kind
  defp reason(%{verdict: :refused, reason: reason}), do: reason
  defp reason(_), do: nil
end
