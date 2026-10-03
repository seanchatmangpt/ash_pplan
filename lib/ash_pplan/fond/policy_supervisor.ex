defmodule AshPPlan.FOND.PolicySupervisor do
  @moduledoc """
  Pure FOND policy lifecycle supervisor.

  It selects policy structure, fences observations by epoch, and reconstructs a
  policy after each admitted nondeterministic outcome. It never executes an action.

  ## The epistemic horizon (K_max)

  The struct carries a `:horizon` (K_max, default `@default_horizon` = 9,
  overridable through `start/4`'s opts) and an `:attempts` counter: every
  admitted `observe/3` reconstruction is one attempt. When the counter has
  reached the horizon, `horizon_exceeded?/1` holds and the NEXT observe is
  a typed refusal `{:error, {:horizon_exceeded, horizon, witness}}` --
  data, never a crash; the witness is the lowercase-hex sha256 over the
  deterministic external term of `{epoch, state, attempts, horizon}`. The
  caller (xaas's L4 `ConvergenceReceipt` mint) maps that tuple onto a
  `BLOCKED(:epistemic_horizon_exceeded)` FAILED_CONVERGENCE receipt. The
  horizon bounds RECONSTRUCTION, never actuation: this module still has no
  execution surface.
  """

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Synthesis

  @default_horizon 9

  @enforce_keys [:domain, :state, :mode, :policy, :epoch]
  defstruct [:domain, :state, :mode, :policy, :epoch, horizon: @default_horizon, attempts: 0]

  @type t :: %__MODULE__{
          domain: FOND.t(),
          state: FOND.state(),
          mode: FOND.mode(),
          policy: FOND.policy(),
          epoch: non_neg_integer(),
          horizon: pos_integer(),
          attempts: non_neg_integer()
        }

  @spec start(FOND.t(), FOND.state(), FOND.mode(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def start(%FOND{} = domain, initial, mode \\ :strong_cyclic, opts \\ []) do
    with {:ok, policy} <- Synthesis.synthesize(domain, initial, mode) do
      {:ok,
       %__MODULE__{
         domain: domain,
         state: initial,
         mode: mode,
         policy: policy,
         epoch: 0,
         horizon: Keyword.get(opts, :horizon, @default_horizon)
       }}
    end
  end

  @doc """
  True iff the supervisor has consumed its horizon: `attempts >= horizon`.
  Pure; the next `observe/3` is the typed `{:horizon_exceeded, k, witness}`
  refusal.
  """
  @spec horizon_exceeded?(t()) :: boolean()
  def horizon_exceeded?(%__MODULE__{attempts: attempts, horizon: horizon}),
    do: attempts >= horizon

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

      horizon_exceeded?(supervisor) ->
        {:error, {:horizon_exceeded, supervisor.horizon, horizon_witness(supervisor)}}

      outcome not in FOND.outcomes(
        supervisor.domain,
        supervisor.state,
        current_action(supervisor)
      ) ->
        {:error, {:unadmitted_outcome, supervisor.state, outcome}}

      true ->
        with {:ok, policy} <- Synthesis.synthesize(supervisor.domain, outcome, supervisor.mode) do
          {:ok,
           %{
             supervisor
             | state: outcome,
               policy: policy,
               epoch: epoch + 1,
               attempts: supervisor.attempts + 1
           }}
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

  # The no-drift fingerprint of the exhausted horizon: lowercase-hex sha256
  # over the deterministic external term of the full horizon binding.
  defp horizon_witness(%__MODULE__{} = supervisor) do
    binding =
      {:ash_pplan_horizon_exceeded, supervisor.epoch, supervisor.state, supervisor.attempts,
       supervisor.horizon}

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(binding, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end
