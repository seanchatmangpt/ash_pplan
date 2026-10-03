defmodule AshPPlan.FOND.Counterexample do
  @moduledoc """
  Normalizes FOND validator and independent-court refusals into portable,
  typed counterexamples. Counterexamples are evidence about a bounded subject;
  they are not execution receipts or authority.
  """

  @spec from_validator(map(), map()) :: map()
  def from_validator(subject, %{reason: reason} = error) do
    %{
      schema: "ash_pplan/fond-counterexample/v1",
      subject_id: subject.id,
      source: :validator,
      class: classify(reason),
      reason: reason,
      witness: witness(error),
      raw: error
    }
  end

  # A malformed validator refusal (no `:reason`) must become a typed
  # counterexample, not a FunctionClauseError crash in the court path.
  def from_validator(subject, error) do
    %{
      schema: "ash_pplan/fond-counterexample/v1",
      subject_id: subject.id,
      source: :validator,
      class: :unclassifiable_validator_result,
      reason: :unclassifiable_validator_result,
      witness: nil,
      raw: error
    }
  end

  @spec from_checker(map(), map()) :: map()
  def from_checker(subject, %{verdict: :refused, kind: kind} = result) do
    %{
      schema: "ash_pplan/fond-counterexample/v1",
      subject_id: subject.id,
      source: :independent_checker,
      class: classify(kind),
      reason: kind,
      witness: Map.get(result, :witness),
      raw: result
    }
  end

  def from_checker(subject, result) do
    %{
      schema: "ash_pplan/fond-counterexample/v1",
      subject_id: subject.id,
      source: :independent_checker,
      class: :unclassifiable_checker_result,
      reason: :unclassifiable_checker_result,
      witness: nil,
      raw: result
    }
  end

  @spec classify(term()) :: atom()
  def classify(reason)
      when reason in [:not_strong, :not_strong_cyclic, :liveness],
      do: :liveness

  def classify(reason)
      when reason in [:missing_policy_action, :unavailable_policy_action, :deadlock],
      do: :deadlock

  def classify(:unknown_initial_state), do: :identity
  def classify(:invalid_policy_request), do: :shape
  def classify(other) when is_atom(other), do: other
  def classify(_), do: :unknown

  defp witness(error) do
    Map.get(error, :losing_states) ||
      Map.get(error, :states_without_goal_path) ||
      Map.get(error, :state) ||
      Map.get(error, :witness)
  end
end
