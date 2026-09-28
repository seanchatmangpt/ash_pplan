defmodule AshPPlan.FOND.TLA.Manifest do
  @moduledoc """
  Content-addressed manifest for a rendered TLA+ policy model.
  """

  @spec from_rendered(map()) :: map()
  def from_rendered(%{module_name: name, module: module, cfg: cfg, mode: mode} = rendered) do
    module_digest = sha256(module)
    cfg_digest = sha256(cfg)

    %{
      schema: "ash_pplan/fond-tla-manifest/v1",
      module_name: name,
      mode: mode,
      module_sha256: module_digest,
      cfg_sha256: cfg_digest,
      subject_sha256: sha256(module_digest <> ":" <> cfg_digest),
      module_bytes: byte_size(module),
      cfg_bytes: byte_size(cfg),
      branches: Map.get(rendered, :branches, []),
      initial: Map.get(rendered, :initial)
    }
  end

  @spec matches?(map(), map()) :: boolean()
  def matches?(manifest, rendered) do
    candidate = from_rendered(rendered)

    manifest[:module_sha256] == candidate.module_sha256 and
      manifest[:cfg_sha256] == candidate.cfg_sha256 and
      manifest[:subject_sha256] == candidate.subject_sha256
  end

  defp sha256(bytes) do
    :crypto.hash(:sha256, bytes)
    |> Base.encode16(case: :lower)
  end
end
