defmodule AshPPlan.FOND.PolicySupervisor do
  @moduledoc """
  Pure FOND policy lifecycle supervisor.

  It selects policy structure, fences observations by epoch, and reconstructs a
  policy after each admitted nondeterministic outcome. It never executes an action.

  ## The epistemic horizon (K_max)

  The struct carries a `:horizon` (K_max, default `@default_horizon` = 9,
  overridable through `start/4`'s opts) and an `:attempts` counter: every
  admitted `observe/3` and `replace_domain/2` reconstruction is one attempt.
  When the counter has
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
    horizon = Keyword.get(opts, :horizon, @default_horizon)

    with {:ok, policy} <- Synthesis.synthesize(domain, initial, mode),
         :ok <- check_horizon(horizon) do
      {:ok,
       %__MODULE__{
         domain: domain,
         state: initial,
         mode: mode,
         policy: policy,
         epoch: 0,
         horizon: horizon
       }}
    end
  end

  # A horizon that is not a non-negative integer would turn every later
  # `attempts >= horizon` comparison into an ArithmeticError crash instead of
  # the typed exhaustion. `0` is legal: the supervisor is born exhausted.
  defp check_horizon(horizon) when is_integer(horizon) and horizon >= 0, do: :ok
  defp check_horizon(horizon), do: {:error, {:invalid_horizon, horizon}}

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

  @doc """
  Reconstructs the supervisor against a new domain. A reconstruction is one
  attempt against the epistemic horizon: it consumes the budget exactly like
  `observe/3`, and refuses with the same typed
  `{:horizon_exceeded, k, witness}` once the budget is gone. Without this,
  a caller could loop `replace_domain/2` forever -- an unbounded
  strong-cyclic loop the horizon never saw.
  """
  @spec replace_domain(t(), term()) :: {:ok, t()} | {:error, term()}
  def replace_domain(%__MODULE__{} = supervisor, domain) do
    cond do
      horizon_exceeded?(supervisor) ->
        {:error, {:horizon_exceeded, supervisor.horizon, horizon_witness(supervisor)}}

      true ->
        with {:ok, policy} <- Synthesis.synthesize(domain, supervisor.state, supervisor.mode) do
          {:ok,
           %{
             supervisor
             | domain: domain,
               policy: policy,
               epoch: supervisor.epoch + 1,
               attempts: supervisor.attempts + 1
           }}
        end
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
