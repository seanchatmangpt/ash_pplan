defmodule AshPPlan.AffidavitBundle do
  @moduledoc """
  Projects `AshPPlan.ExecutionReceipt`s into an **omni-evidence/v1 bundle**: the
  cross-repo interchange that affidavit certifies (`affi receipt emit-batch`).

  ash_pplan observes; affidavit certifies; neither decides for the other. This
  module mints no BLAKE3 commitment and no chain hash: affidavit computes the
  payload commitment (`blake3(payload bytes)`) and seals the chain at
  `affi receipt assemble`. ash_pplan's own content addresses (the outcome
  digest, the release-binding digest) travel *inside* the payload, as the
  N-Triples `ExecutionReceipt.to_rdf/2` already emits.

  ## Bundle layout (omni-evidence/v1)

      <dir>/batch.json              JSON array, one entry per event
      <dir>/payloads/0000.nt        payload bytes, one file per event

  Each `batch.json` entry is `{"event_type", "objects", "payload"}`. `payload`
  is a path relative to the bundle directory (affidavit resolves it against the
  batch file's directory). `objects` are affidavit object refs
  `id:type[:qualifier]`: the `id` is a colon-free derived token and the
  qualifier carries the raw identity (an IRI may contain colons; affidavit
  splits on the first two only).

  The schema lives in affidavit (`schemas/omni-evidence-batch.v1.schema.json`).

  ## Certify

      AshPPlan.AffidavitBundle.write!(AshPPlan.AffidavitBundle.entries([receipt]), "out/")
      # then, in a scratch dir:
      affi receipt emit-batch --batch-file out/batch.json
      affi receipt assemble --out receipt.json
      affi verify receipt.json        # exit 0 ACCEPT / 2 REJECT

  Determinism: the same receipts in the same order produce byte-identical
  bundles (no wall clock, no random ids; timestamps come from the receipts).
  """

  alias AshPPlan.ExecutionReceipt

  @format "omni-evidence/v1"

  @typedoc "One bundle entry before it is written."
  @type entry :: %{event_type: String.t(), objects: [String.t()], payload: binary()}

  @doc "The interchange format tag this module writes."
  @spec format() :: String.t()
  def format, do: @format

  @doc """
  Build bundle entries from execution receipts, in order. Pure.

  `opts` are passed through to `ExecutionReceipt.to_rdf/2` (for example
  `:corresponds_to_steps`).
  """
  @spec entries([ExecutionReceipt.t()], keyword()) :: [entry()]
  def entries(receipts, opts \\ []) when is_list(receipts) do
    Enum.map(receipts, &entry(&1, opts))
  end

  @doc "Build one bundle entry from one execution receipt. Pure."
  @spec entry(ExecutionReceipt.t(), keyword()) :: entry()
  def entry(%ExecutionReceipt{} = receipt, opts \\ []) do
    run = ExecutionReceipt.run_identifier(receipt.run_id)

    objects =
      [
        object_ref("run", "pplan-run", run),
        object_ref("plan", "pplan-plan", receipt.plan_iri)
      ] ++ subject_ref(receipt)

    %{
      event_type: "pplan.execution." <> Atom.to_string(receipt.status),
      objects: objects,
      payload: ExecutionReceipt.to_rdf(receipt, opts)
    }
  end

  @doc """
  Build an affidavit object ref `id:type:qualifier`.

  The id is `<prefix>-<first 16 hex of sha256(raw)>` (colon-free, stable); the
  raw value rides in the qualifier so no identity is lost.
  """
  @spec object_ref(String.t(), String.t(), String.t()) :: String.t()
  def object_ref(prefix, type, raw) when is_binary(raw) do
    short = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    "#{prefix}-#{short}:#{type}:#{raw}"
  end

  defp subject_ref(%ExecutionReceipt{subject_sha: sha, repo: repo}) when is_binary(sha) do
    ["#{sha}:git-commit:#{repo || "unknown"}"]
  end

  defp subject_ref(_receipt), do: []

  @doc """
  Render `batch.json` for `entries`, pointing at `payloads/NNNN.nt`. Pure.
  Returns `{batch_json, [{relative_path, payload_bytes}]}`.
  """
  @spec render([entry()]) :: {String.t(), [{String.t(), binary()}]}
  def render(entries) when is_list(entries) do
    indexed = Enum.with_index(entries)

    files = Enum.map(indexed, fn {e, i} -> {payload_path(i), e.payload} end)

    rows =
      Enum.map(indexed, fn {e, i} ->
        "  {" <>
          ~s("event_type":) <>
          json_string(e.event_type) <>
          "," <>
          ~s("objects":[) <>
          Enum.map_join(e.objects, ",", &json_string/1) <>
          "]," <>
          ~s("payload":) <> json_string(payload_path(i)) <> "}"
      end)

    {"[\n" <> Enum.join(rows, ",\n") <> "\n]\n", files}
  end

  @doc "Write a bundle for `entries` into `dir` (created if missing). Returns `dir`."
  @spec write!([entry()], Path.t()) :: Path.t()
  def write!(entries, dir) do
    {batch, files} = render(entries)
    File.mkdir_p!(Path.join(dir, "payloads"))

    Enum.each(files, fn {rel, bytes} -> File.write!(Path.join(dir, rel), bytes) end)
    File.write!(Path.join(dir, "batch.json"), batch)
    dir
  end

  defp payload_path(i),
    do: "payloads/" <> String.pad_leading(Integer.to_string(i), 4, "0") <> ".nt"

  @doc false
  # Minimal JSON string encoder (RFC 8259 §7): keeps the bundle dependency-free
  # and byte-stable across encoder versions.
  @spec json_string(String.t()) :: String.t()
  def json_string(s) when is_binary(s) do
    escaped =
      for <<c::utf8 <- s>>, into: "" do
        case c do
          ?" -> "\\\""
          ?\\ -> "\\\\"
          ?\n -> "\\n"
          ?\r -> "\\r"
          ?\t -> "\\t"
          c when c < 0x20 -> "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0")
          c -> <<c::utf8>>
        end
      end

    "\"" <> escaped <> "\""
  end
end
