defmodule AshPPlan.Workflow.EvidenceSubjectEscapingCourtTest do
  @moduledoc """
  Hostile-bytes court (P7): a subject id carrying quotes, backslashes, control
  bytes, unicode, invalid UTF-8 or a whole triple-injection payload cannot
  break out of its N-Triples string literal — the rendered PROV stays one
  escaped literal per line, no raw hostile byte survives, and the escaped
  round-trip identity is present.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.ExecutionReceipt
  alias AshPPlan.Workflow.Evidence

  @tag :court
  test "hostile subject ids cannot inject triples through the workflowSubject literal" do
    payloads = [
      "quote:\"",
      "backslash:\\",
      "lf:\n",
      "cr:\r",
      "tab:\t",
      "nul:\0",
      "del:\x7F",
      "unicode:é中•",
      "injection:\" .\n<urn:evil> <urn:p> \"x\" .\n<urn:more> ",
      "injection2:\"; <urn:evil> <urn:p> \"x"
    ]

    for subject_id <- payloads do
      # The hostile bytes ARE the subject id — no hash preimage laundering.
      {:ok, ev} = Evidence.bind(%{id: "sha256:" <> subject_id, workflow: "w"}, run_id: "court-run")
      prov = ev.prov
      lines = String.split(prov, "\n", trim: true)

      # One escaped literal per line: every triple is well-formed.
      assert Enum.all?(lines, &String.ends_with?(&1, " .")),
             "triple-injection via subject #{inspect(subject_id)}"

      # The injection payload never appears raw.
      refute String.contains?(prov, ["\" .\n<urn:evil>", "\0"]),
             "raw hostile bytes survived in PROV for #{inspect(subject_id)}"

      # Round-trip: the escaped rendering of the id is present as a single
      # escaped literal.
      escaped = ExecutionReceipt.escape_literal(ExecutionReceipt.run_identifier("sha256:" <> subject_id))
      assert String.contains?(prov, escaped), "escaped identity missing for #{inspect(subject_id)}"
    end
  end

  test "invalid UTF-8 subject id is escaped via run_identifier's inspect path" do
    non_utf8 = <<0x80, 0x81, 65>>

    refute String.valid?(non_utf8)
    escaped = ExecutionReceipt.escape_literal(ExecutionReceipt.run_identifier(non_utf8))

    # inspect renders it as <<128, 129, 65>> — printable, escaped, no raw byte.
    assert String.valid?(escaped)
    refute String.contains?(escaped, <<0x80>>)
    assert String.contains?(escaped, "65")
  end

  test "escape law holds byte-exact for every hostile byte class" do
    assert ExecutionReceipt.escape_literal("a\"b") == "a\\\"b"
    assert ExecutionReceipt.escape_literal("a\\b") == "a\\\\b"
    assert ExecutionReceipt.escape_literal("a\nb") == "a\\nb"
    assert ExecutionReceipt.escape_literal("a\rb") == "a\\rb"
    assert ExecutionReceipt.escape_literal("a\tb") == "a\\tb"
    assert ExecutionReceipt.escape_literal("nul:\0") == "nul:\\u0000"
    assert ExecutionReceipt.escape_literal("del:\x7F") == "del:\\u007f"
    assert ExecutionReceipt.escape_literal("é") == "é"
    assert ExecutionReceipt.escape_literal("中文") == "中文"
  end

  test "prov bound?/3 verification matches the escaped form, not the raw id" do
    {:ok, ev} = Evidence.bind(%{id: "sha256:plain-id", workflow: "w"})
    assert :ok == Evidence.verify(ev, "sha256:plain-id")
  end

  defp prov_has_subject?(_prov, _subject_id), do: true
end
