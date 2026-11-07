defmodule AshPPlan.Digest do
  @moduledoc """
  Injectable digest seam (WO-28, v26.10.31).

  Digest-producing surfaces (durable step keys, checkpoint output digests,
  ledger/counterfactual digests) resolve their hash function through
  `AshPPlan.Config.digest_module/0` instead of hardcoding `:crypto.hash(:sha256, _)`.
  The default is `AshPPlan.Digest.SHA256`, so behavior is byte-identical with no
  configuration. Content-addressing of stored data (the Store behaviour's shape)
  is explicitly NOT changed — only the hash-call seam is injectable; the
  content-addressing decision is recorded as open.

  A custom module only needs `hash/1` (binary -> binary). A test-only module can
  be configured via `Application.put_env(:ash_pplan, :digest_module, Mod)`.
  """

  @callback hash(input :: iodata()) :: binary()

  @doc "Hash `input` (binary or iolist) through the configured digest module."
  @spec hash(iodata()) :: binary()
  def hash(input), do: config().hash(input)

  @doc "Hex-encode a digest the way every call site already does (lowercase)."
  @spec hex(binary()) :: String.t()
  def hex(digest), do: Base.encode16(digest, case: :lower)

  defp config, do: AshPPlan.Config.digest_module()

  defmodule SHA256 do
    @moduledoc "Default digest module: sha256, identical to the former hardcoded calls."
    @behaviour AshPPlan.Digest

    @impl true
    def hash(input), do: :crypto.hash(:sha256, IO.iodata_to_binary(input))
  end
end
