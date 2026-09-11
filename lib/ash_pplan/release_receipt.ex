defmodule AshPPlan.ReleaseReceipt do
  @moduledoc """
  Content-addressed evidence about one exact release head.

  `planning/ship_v26_9_6.hddl` makes `observed` and `receipted` release goals,
  and `AGENTS.md` requires CI against an exact head before a release may claim
  `ALIVE` standing.

  The receipt binds the Git commit identity to every semantic/manufactured
  input the release gate depends on. Source digests are captured at compile
  time; the exact Git head is supplied by the repository gate at observation
  time. This means neither a source change nor a code/workflow commit can keep
  the same release receipt identity.

  A release receipt is evidence, not authority. It does not publish, tag, or
  approve anything, and it grants no standing on its own — CI observing a green
  exact head is what grants standing; this records which head that was.
  """

  @root Path.expand("../..", __DIR__)

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

  @enforce_keys [:release, :head, :sources, :digest]
  defstruct [:release, :head, :sources, :digest]

  @type t :: %__MODULE__{
          release: String.t(),
          head: String.t(),
          sources: [{String.t(), String.t()}],
          digest: String.t()
        }

  @doc """
  Returns the release receipt bound to the exact Git head that was observed.
  """
  @spec observe(String.t()) :: t()
  def observe(head_sha) when is_binary(head_sha) do
    head_sha = validate_head!(head_sha)

    %__MODULE__{
      release: AshPPlan.version(),
      head: head_sha,
      sources: @observed_sources,
      digest: digest(head_sha, AshPPlan.version(), @observed_sources)
    }
  end

  @doc """
  Returns the SHA-256 digest of the Git head, release identity and observed sources.

  Exposed so a change to the head or any single input can be shown to change
  the receipt, rather than the content-addressing being asserted in prose.
  """
  @spec digest(String.t(), String.t(), [{String.t(), String.t()}]) :: String.t()
  def digest(head_sha, release, sources)
      when is_binary(head_sha) and is_binary(release) and is_list(sources) do
    head_sha = validate_head!(head_sha)

    sources
    |> Enum.sort()
    |> Enum.map_join("\n", fn {name, source_digest} -> "#{name}=#{source_digest}" end)
    |> then(&"ash_pplan #{release}\nhead=#{head_sha}\n#{&1}\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Returns the observed source digests as a name-keyed map."
  @spec sources() :: %{String.t() => String.t()}
  def sources, do: Map.new(@observed_sources)

  @doc """
  Renders a bound receipt as deterministic JSON.

  Every value is a release identity, Git object identity or hex digest, so this
  needs no JSON library and adds no runtime dependency to a semantics-only
  projection.
  """
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = receipt) do
    sources =
      receipt.sources
      |> Enum.sort()
      |> Enum.map_join(",\n", fn {name, source_digest} ->
        ~s(    "#{name}": "#{source_digest}")
      end)

    """
    {
      "release": "#{receipt.release}",
      "head": "#{receipt.head}",
      "digest": "#{receipt.digest}",
      "sources": {
    #{sources}
      }
    }
    """
  end

  defp validate_head!(head_sha) do
    if Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, head_sha) do
      head_sha
    else
      raise ArgumentError,
            "release receipt requires an exact 40- or 64-hex Git commit identity"
    end
  end
end
