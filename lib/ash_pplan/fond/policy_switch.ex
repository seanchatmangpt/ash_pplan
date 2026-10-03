defmodule AshPPlan.FOND.PolicySwitch do
  @moduledoc """
  Deterministic policy-mode selection over the existing synthesis and validation
  primitives.

  Switching changes candidate semantics only. It never resumes or actuates a
  runtime.

  ## The epistemic horizon (K_max)

  The mode sweep accepts `opts[:horizon]` (K_max, default 9): each failed
  mode attempt is one attempt, and a sweep that has consumed the horizon
  stops as a typed refusal `{:error, {:horizon_exceeded, k, witness}}` --
  the same exhaustion shape `FOND.PolicySupervisor.observe/3` returns and
  the shape xaas's L4 `ConvergenceReceipt` mint maps onto
  `BLOCKED(:epistemic_horizon_exceeded)`. The witness is the lowercase-hex
  sha256 over the deterministic external term of the attempted
  `{mode, reason}` pairs. With the default horizon a full two-mode sweep
  can never exhaust (2 < 9), so today's `:no_admitted_policy` behavior is
  unchanged unless the caller lowers the horizon.
  """

  alias AshPPlan.FOND
  alias AshPPlan.FOND.{Subject, Synthesis}

  @default_modes [:strong, :strong_cyclic]
  @default_horizon 9

  @spec select(FOND.t(), FOND.state(), keyword()) ::
          {:ok, map()}
          | {:error, map()}
          | {:error, {:horizon_exceeded, pos_integer(), String.t()}}
  def select(domain, initial, opts \\ [])

  def select(%FOND{} = domain, initial, opts) do
    modes = Keyword.get(opts, :modes, @default_modes)
    horizon = Keyword.get(opts, :horizon, @default_horizon)

    cond do
      not is_list(modes) -> {:error, {:invalid_modes, modes}}
      not (is_integer(horizon) and horizon >= 0) -> {:error, {:invalid_horizon, horizon}}
      true -> sweep(domain, initial, modes, horizon)
    end
  end

  def select(domain, initial, _opts),
    do: {:error, %{reason: :invalid_domain, domain: domain, initial: initial}}

  defp sweep(domain, initial, modes, horizon) do
    modes
    |> Enum.reduce_while({:error, []}, fn mode, {:error, attempts} ->
      case synthesize_and_validate(domain, initial, mode) do
        {:ok, result} ->
          {:halt, {:ok, Map.put(result, :attempts, Enum.reverse(attempts))}}

        {:error, reason} ->
          attempts = [{mode, reason} | attempts]

          # a sweep that has consumed the horizon refuses with the typed
          # error at exactly horizon (the attempt counts, not the next one)
          if length(attempts) >= horizon do
            {:halt, {:error, {:horizon_exceeded, horizon, horizon_witness(attempts)}}}
          else
            {:cont, {:error, attempts}}
          end
      end
    end)
    |> case do
      {:ok, result} ->
        {:ok, result}

      {:error, {:horizon_exceeded, _k, _witness} = exhausted} ->
        {:error, exhausted}

      {:error, attempts} ->
        {:error,
         %{
           reason: :no_admitted_policy,
           initial: initial,
           attempted_modes: Enum.reverse(attempts)
         }}
    end
  end

  # The no-drift fingerprint of the exhausted sweep: the attempted
  # {mode, reason} pairs in order, over the deterministic external term.
  defp horizon_witness(attempts) do
    :sha256
    |> :crypto.hash(
      :erlang.term_to_binary({:policy_switch_horizon_exceeded, attempts}, [:deterministic])
    )
    |> Base.encode16(case: :lower)
  end

  defp synthesize_and_validate(domain, initial, mode) when mode in [:strong, :strong_cyclic] do
    with {:ok, policy} <- Synthesis.synthesize(domain, initial, mode),
         {:ok, validation} <- FOND.validate_policy(domain, policy, initial, mode) do
      {:ok,
       %{
         mode: mode,
         policy: policy,
         validation: validation,
         subject: Subject.bind(domain, policy, initial, mode)
       }}
    end
  end

  defp synthesize_and_validate(_domain, _initial, mode),
    do: {:error, {:invalid_mode, mode}}
end
