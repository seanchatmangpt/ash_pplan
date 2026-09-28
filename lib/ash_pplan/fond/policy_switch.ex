defmodule AshPPlan.FOND.PolicySwitch do
  @moduledoc """
  Deterministic policy-mode selection over the existing synthesis and validation
  primitives.

  Switching changes candidate semantics only. It never resumes or actuates a
  runtime.
  """

  alias AshPPlan.FOND
  alias AshPPlan.FOND.{Subject, Synthesis}

  @default_modes [:strong, :strong_cyclic]

  @spec select(FOND.t(), FOND.state(), keyword()) :: {:ok, map()} | {:error, map()}
  def select(domain, initial, opts \\ [])

  def select(%FOND{} = domain, initial, opts) do
    modes = Keyword.get(opts, :modes, @default_modes)

    modes
    |> Enum.reduce_while({:error, []}, fn mode, {:error, attempts} ->
      case synthesize_and_validate(domain, initial, mode) do
        {:ok, result} -> {:halt, {:ok, Map.put(result, :attempts, Enum.reverse(attempts))}}
        {:error, reason} -> {:cont, {:error, [{mode, reason} | attempts]}}
      end
    end)
    |> case do
      {:ok, result} ->
        {:ok, result}

      {:error, attempts} ->
        {:error,
         %{
           reason: :no_admitted_policy,
           initial: initial,
           attempted_modes: Enum.reverse(attempts)
         }}
    end
  end

  def select(domain, initial, _opts),
    do: {:error, %{reason: :invalid_domain, domain: domain, initial: initial}}

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
