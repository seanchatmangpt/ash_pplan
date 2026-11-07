defmodule AshPPlan.FOND.Replay do
  @moduledoc """
  Deterministic replay bundle for a FOND/TLA differential episode.

  A replay bundle freezes the exact subject identity, rendered model, native
  verdict and optional seed. It is evidence input for a future court, not proof
  that the court was executed.
  """

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Subject
  alias AshPPlan.FOND.TLA.Manifest

  @schema "ash_pplan/fond-replay/v1"

  @doc """
  Total predicate: true when `term` survives `:erlang.term_to_binary([:deterministic])`
  hashing (`fingerprint/1`) without raising or destroying determinism.

  Functions, pids, references, ports and any term containing one at any depth are
  unhashable. Atoms, numbers, binaries, maps, lists and tuples are checked
  structurally, so the predicate never raises and always answers.
  """
  @spec hashable?(term()) :: boolean()
  def hashable?(term) when is_function(term) or is_pid(term) or is_reference(term), do: false
  def hashable?(term) when is_port(term), do: false
  def hashable?([]), do: true

  def hashable?(term) when is_map(term) do
    term |> Map.to_list() |> do_hashable_list()
  end

  def hashable?(term) when is_list(term), do: do_hashable_list(term)

  def hashable?(term) when is_tuple(term) do
    term |> Tuple.to_list() |> do_hashable_list()
  end

  def hashable?(_other), do: true

  defp do_hashable_list([head | tail]), do: hashable?(head) and do_hashable_list(tail)
  defp do_hashable_list([]), do: true

  @spec build(FOND.t(), FOND.policy(), FOND.state(), FOND.mode(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def build(%FOND{} = domain, policy, initial, mode, opts \\ []) do
    with :ok <- hashable_preflight(initial, Keyword.get(opts, :seed)) do
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
  end

  # Hostile-input pre-flight: a replay bundle is hashed with
  # `:erlang.term_to_binary([:deterministic])`, which raises on functions, pids
  # and refs — refuse them typed, tagged with the offending field, before any
  # subject binding or rendering happens.
  defp hashable_preflight(initial, seed) do
    cond do
      not hashable?(initial) -> {:error, {:unhashable_term, :initial}}
      not is_nil(seed) and not hashable?(seed) -> {:error, {:unhashable_term, :seed}}
      true -> :ok
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
