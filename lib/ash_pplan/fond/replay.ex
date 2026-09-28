defmodule AshPPlan.FOND.Replay do
  @moduledoc """
  Deterministic replay bundle for a FOND/TLA differential episode.

  A replay bundle freezes the exact subject identity, rendered model, native
  verdict and optional seed. It is evidence input for a future court, not proof
  that the court was executed.
  """

  alias AshPPlan.FOND
  alias AshPPlan.FOND.{Subject, TLA.Manifest}

  @schema "ash_pplan/fond-replay/v1"

  @spec build(FOND.t(), FOND.policy(), FOND.state(), FOND.mode(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def build(%FOND{} = domain, policy, initial, mode, opts \\ []) do
    subject = Subject.bind(domain, policy, initial, mode)

    with {:ok, rendered} <- FOND.to_tla(domain, policy, initial, mode, opts) do
      native = FOND.validate_policy(domain, policy, initial, mode)

      {:ok,
       %{
         schema: @schema,
         subject: Map.drop(subject, [:normalized]),
         normalized_subject: subject.normalized,
         seed: Keyword.get(opts, :seed),
         native_verdict: verdict(native),
         native_result: native,
         tla: Manifest.from_rendered(rendered)
       }}
    end
  end

  @spec fingerprint(map()) :: String.t()
  def fingerprint(bundle) when is_map(bundle) do
    digest =
      bundle
      |> Map.delete(:replay_fingerprint)
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "sha256:" <> digest
  end

  @spec bind_fingerprint(map()) :: map()
  def bind_fingerprint(bundle), do: Map.put(bundle, :replay_fingerprint, fingerprint(bundle))

  defp verdict({:ok, _}), do: :admitted
  defp verdict({:error, _}), do: :refused
end
