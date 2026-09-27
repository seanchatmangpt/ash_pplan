defmodule AshPPlan.FOND.PolicySupervisor do
  @moduledoc """
  Pure FOND policy lifecycle supervisor.

  It selects policy structure, fences observations by epoch, and reconstructs a
  policy after each admitted nondeterministic outcome. It never executes an action.
  """

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Synthesis

  @enforce_keys [:domain, :state, :mode, :policy, :epoch]
  defstruct [:domain, :state, :mode, :policy, :epoch]

  @type t :: %__MODULE__{
          domain: FOND.t(),
          state: FOND.state(),
          mode: FOND.mode(),
          policy: FOND.policy(),
          epoch: non_neg_integer()
        }

  def start(%FOND{} = domain, initial, mode \\ :strong_cyclic) do
    with {:ok, policy} <- Synthesis.synthesize(domain, initial, mode) do
      {:ok, %__MODULE__{domain: domain, state: initial, mode: mode, policy: policy, epoch: 0}}
    end
  end

  def intent(%__MODULE__{} = supervisor) do
    cond do
      MapSet.member?(supervisor.domain.goals, supervisor.state) ->
        {:ok, %{kind: :goal, state: supervisor.state, epoch: supervisor.epoch}}

      true ->
        case Map.fetch(supervisor.policy, supervisor.state) do
          {:ok, action} ->
            {:ok,
             %{
               kind: :fond_action,
               state: supervisor.state,
               action: action,
               epoch: supervisor.epoch
             }}

          :error ->
            {:error, {:missing_policy_action, supervisor.state}}
        end
    end
  end

  def observe(%__MODULE__{epoch: epoch} = supervisor, expected_epoch, outcome) do
    cond do
      expected_epoch != epoch ->
        {:error, {:stale_epoch, expected_epoch, epoch}}

      outcome not in FOND.outcomes(supervisor.domain, supervisor.state, current_action(supervisor)) ->
        {:error, {:unadmitted_outcome, supervisor.state, outcome}}

      true ->
        with {:ok, policy} <- Synthesis.synthesize(supervisor.domain, outcome, supervisor.mode) do
          {:ok, %{supervisor | state: outcome, policy: policy, epoch: epoch + 1}}
        end
    end
  end

  def replace_domain(%__MODULE__{} = supervisor, %FOND{} = domain) do
    with {:ok, policy} <- Synthesis.synthesize(domain, supervisor.state, supervisor.mode) do
      {:ok, %{supervisor | domain: domain, policy: policy, epoch: supervisor.epoch + 1}}
    end
  end

  defp current_action(supervisor) do
    Map.get(supervisor.policy, supervisor.state)
  end
end
