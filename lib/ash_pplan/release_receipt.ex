defmodule AshPPlan.ReleaseReceipt do
  @moduledoc """
  Content-addressed evidence about one exact release head.

  `planning/ship_v26_9_6.hddl` makes `observed` and `receipted` release goals,
  and `AGENTS.md` requires CI against an exact head before a release may claim
  `ALIVE` standing. Nothing executable recorded that observation, so the goals
  could only ever be asserted in prose.

  This module closes that: every input the release gate depends on is digested
  at compile time, so the receipt describes the head that was actually built
  rather than whatever happens to be on disk when it is read.

  A release receipt is evidence, not authority. It does not publish, tag, or
  approve anything, and it grants no standing on its own — CI observing a green
  exact head is what grants standing; this records which head that was.
  """

  @root Path.expand("../..", __DIR__)

  # Digesting these at compile time (and declaring them as external resources)
  # means editing any of them forces a recompile, so a stale receipt cannot
  # survive a change to the semantic source or its manufactured projections.
  @sources [
    {"ontology.ttl", Path.join(@root, "ontology.ttl")},
    {"ontology/shapes.ttl", Path.join(@root, "ontology/shapes.ttl")},
    {"ecosystem.lock.toml", Path.join(@root, "ecosystem.lock.toml")},
    {"lib/ash_pplan/generated/projection_catalog.ex",
     Path.join(@root, "lib/ash_pplan/generated/projection_catalog.ex")},
    {"lib/ash_pplan/generated/plan_catalog.ex",
     Path.join(@root, "lib/ash_pplan/generated/plan_catalog.ex")}
  ]

  for {_name, path} <- @sources do
    @external_resource path
  end

  @observed_sources Enum.map(@sources, fn {name, path} ->
                      {name,
                       path
                       |> File.read!()
                       |> then(&:crypto.hash(:sha256, &1))
                       |> Base.encode16(case: :lower)}
                    end)

  @enforce_keys [:release, :sources, :digest]
  defstruct [:release, :sources, :digest]

  @type t :: %__MODULE__{
          release: String.t(),
          sources: [{String.t(), String.t()}],
          digest: String.t()
        }

  @doc """
  Returns the release receipt for the head this module was compiled from.
  """
  @spec observe() :: t()
  def observe do
    %__MODULE__{
      release: AshPPlan.version(),
      sources: @observed_sources,
      digest: digest(AshPPlan.version(), @observed_sources)
    }
  end

  @doc """
  Returns the SHA-256 digest of a release identity and its observed sources.

  Exposed so a change to any single input can be shown to change the receipt,
  rather than the content-addressing being asserted in prose.
  """
  @spec digest(String.t(), [{String.t(), String.t()}]) :: String.t()
  def digest(release, sources) when is_binary(release) and is_list(sources) do
    sources
    |> Enum.sort()
    |> Enum.map_join("\n", fn {name, source_digest} -> "#{name}=#{source_digest}" end)
    |> then(&"ash_pplan #{release}\n#{&1}\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Returns the observed source digests as a name-keyed map."
  @spec sources() :: %{String.t() => String.t()}
  def sources, do: Map.new(@observed_sources)

  @doc """
  Renders the receipt as deterministic JSON.

  Every value is a release identity or a hex digest, so this needs no JSON
  library and adds no runtime dependency to a semantics-only projection.
  """
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = receipt \\ observe()) do
    sources =
      receipt.sources
      |> Enum.sort()
      |> Enum.map_join(",\n", fn {name, digest} ->
        ~s(    "#{name}": "#{digest}")
      end)

    """
    {
      "release": "#{receipt.release}",
      "digest": "#{receipt.digest}",
      "sources": {
    #{sources}
      }
    }
    """
  end
end
