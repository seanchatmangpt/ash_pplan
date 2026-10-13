defmodule AshPPlan.Standing.PortableProjection do
  @moduledoc """
  Pure projection from `AshPPlan.Standing.Receipt`'s standing vocabulary onto
  ggen's portable receipt envelope vocabulary (RFC-GPACK-001 §54-56, schema
  `https://ggen.dev/receipt/pack/v1`, canonical source read-only at
  `/Users/sac/ggen/crates/ggen-engine/schema/receipt-portable.schema.json`).

  The vocabularies are NOT equivalent (same reading as ggen_igniter's
  `receipt_portable_boundary_test.exs` precedent). This module does not unify
  them; it makes every crossing explicit and total:

    * direct counterparts project (`ALIVE`, `PARTIAL_ALIVE`, `BLOCKED`,
      `BUILD_BROKEN`, `UNSUPPORTED`);
    * `REFUSED(x)` projects to `"REFUSED:" <> x` — the ggen standing pattern
      only admits `REFUSED:[A-Z0-9_]+`, so a payload is REQUIRED and its
      characters are validated, never rewritten (a bare `REFUSED` or a
      non-conforming payload is a typed refusal, not a silent rewrite);
    * `COMPENSATED`, `COMPENSATION_FAILED` and `UNKNOWN` have no ggen
      counterpart and are returned as `:no_ggen_counterpart` dispositions —
      never silently dropped. Note ggen's portable standing pattern has no
      `UNKNOWN` at all; ggen carries unknownness on other envelope fields
      (`replay.status = "UNKNOWN"`, `UNKNOWN` digests) instead.

  Identity anchors (`subject_sha`/`base_sha`) are validated against ggen's
  64-hex digest convention. The exec receipt (`AshPPlan.ExecutionReceipt`)
  enforces 40-hex — a 40-hex anchor still projects unchanged (never
  truncated or padded), but carries an explicit `:sha_length_mismatch` flag
  in the report so the length skew is disclosed, not papered over.

  ## Ontology gap (disclosed, not fixed)

  `AshPPlan.ExecutionReceipt`'s moduledoc names `ap:repo`/`ap:subjectSha`/
  `ap:baseSha` as "still need declaring in the canonical ontology". That
  declaration is NOT made here: `priv/ggen/ash-pplan-standing-pack/ontology.ttl`
  feeds generated code (`Standing.Receipt` is `# GENERATED`), SPARQL gates,
  anti-vacuity fixtures and the qualification receipt, so a change there is a
  requalification transition, not a zero-behavior additive edit. Deferred to
  the owning lane.
  """

  @ggen_schema "https://ggen.dev/receipt/pack/v1"
  @hex40 ~r/^[0-9a-f]{40}$/
  @hex64 ~r/^[0-9a-f]{64}$/
  @refused_payload ~r/^[A-Z0-9_]+$/

  @direct ~w(ALIVE PARTIAL_ALIVE BLOCKED BUILD_BROKEN UNSUPPORTED)
  @no_counterpart ~w(COMPENSATED COMPENSATION_FAILED UNKNOWN)

  @type disposition :: :no_ggen_counterpart | {:no_ggen_counterpart, atom()} | {:error, map()}
  @type standing_projection ::
          {:ok, String.t()} | {:no_ggen_counterpart, atom()} | {:error, map()}

  @doc "The ggen portable envelope schema URI this projection targets."
  @spec ggen_schema() :: String.t()
  def ggen_schema, do: @ggen_schema

  @doc "Standing values that project directly onto ggen's vocabulary."
  @spec direct_standings() :: [String.t()]
  def direct_standings, do: @direct

  @doc "Standing values with no ggen counterpart (explicitly dispositioned)."
  @spec no_counterpart_standings() :: [String.t()]
  def no_counterpart_standings, do: @no_counterpart

  @doc """
  Project one standing value (atom or string) into ggen's portable standing
  vocabulary. Total over the closed set `AshPPlan.Standing.Receipt.standings/0`:
  every admitted value returns `{:ok, binary}` or an explicit
  `{:no_ggen_counterpart, reason}`; anything outside the closed set returns
  `{:error, {:unknown_standing, value}}` so totality fails loudly.
  """
  @spec project_standing(atom() | String.t()) :: standing_projection()
  def project_standing(value) do
    s = to_string(value)

    cond do
      s in @direct ->
        {:ok, s}

      s in @no_counterpart ->
        {:no_ggen_counterpart, no_counterpart_reason(s)}

      s == "REFUSED" ->
        {:error, %{broken_term: "refused_requires_ggen_payload"}}

      String.starts_with?(s, "REFUSED:") ->
        project_refused(s)

      true ->
        {:error, {:unknown_standing, value}}
    end
  end

  defp project_refused("REFUSED:" <> payload) do
    if Regex.match?(@refused_payload, payload),
      do: {:ok, "REFUSED:" <> payload},
      else: {:error, %{broken_term: "refused_payload_not_ggen_conformant", payload: payload}}
  end

  defp no_counterpart_reason("COMPENSATED"), do: :compensated
  defp no_counterpart_reason("COMPENSATION_FAILED"), do: :compensation_failed
  defp no_counterpart_reason("UNKNOWN"), do: :unknown_standing

  @doc """
  Project the subject-identity anchors (`subject_sha`, `base_sha`) toward
  ggen's 64-hex digest convention. Each present anchor is validated as
  lowercase hex; 64-hex projects clean, 40-hex (the `ExecutionReceipt`
  convention) projects UNCHANGED with an explicit `:sha_length_mismatch`
  flag — never truncated, never padded. A present anchor that is neither is
  a typed refusal. Absent anchors are honest absence, not an error.
  """
  @spec project_identity(keyword() | map()) ::
          {:ok, %{subject_sha: String.t() | nil, base_sha: String.t() | nil, flags: [atom()]}} |
          {:error, {:bad_identity, atom()}}
  def project_identity(opts) do
    with {:ok, subject} <- anchor(opts, :subject_sha),
         {:ok, base} <- anchor(opts, :base_sha) do
      flags =
        for {_k, v} <- [subject: subject, base: base],
            is_binary(v) and Regex.match?(@hex40, v),
            do: :sha_length_mismatch

      {:ok, %{subject_sha: subject, base_sha: base, flags: flags}}
    end
  end

  defp anchor(opts, key) do
    v = if is_map(opts), do: Map.get(opts, key, Map.get(opts, Atom.to_string(key))), else: Keyword.get(opts, key)

    cond do
      is_nil(v) -> {:ok, nil}
      is_binary(v) and Regex.match?(@hex64, v) -> {:ok, v}
      is_binary(v) and Regex.match?(@hex40, v) -> {:ok, v}
      true -> {:error, {:bad_identity, key}}
    end
  end

  @doc """
  Totality report for one receipt surface: the standing projection plus the
  identity projection plus explicit dispositions. A standing with no ggen
  counterpart appears in `dispositions` — it is counted and named, never
  dropped. Every entry of `AshPPlan.Standing.Receipt.standings/0` produces a
  report with a non-nil `:standing` key (totality); an invented standing
  value makes the report an error, which is what the sabotage twin asserts.
  """
  @spec projection_report(atom() | String.t(), keyword() | map()) :: map()
  def projection_report(standing, identity_opts \\ []) do
    {standing_out, dispositions} =
      case project_standing(standing) do
        {:ok, projected} ->
          {{:ok, projected}, []}

        {:no_ggen_counterpart, reason} ->
          {nil, [%{field: :standing, value: to_string(standing), reason: reason}]}

        {:error, reason} ->
          {{:error, reason}, []}
      end

    identity_out =
      case project_identity(identity_opts) do
        {:ok, identity} -> identity
        {:error, reason} -> {:error, reason}
      end

    %{
      ggen_schema: @ggen_schema,
      standing: standing_out,
      identity: identity_out,
      dispositions: dispositions
    }
  end
end
