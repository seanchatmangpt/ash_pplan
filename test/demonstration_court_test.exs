defmodule AshPPlan.DemonstrationCourtTest do
  @moduledoc """
  Court: `bin/demonstrate` is a one-command reproducible demonstration receipt
  (`docs/demonstration.md`, claims vs evidence).

  This court runs the real script end to end and demands: exit 0, a PASS row
  for every named evidence edge, and no FAIL row anywhere in the receipt. A
  SKIP row is tolerated only when it carries an explicit reason string.

  Anti-vacuity mutation: the receipt parser itself is exercised against two
  mutants — a receipt with a FAIL row and a receipt whose SKIP rows carry no
  reason — and must be refused in both cases, so an empty or forged receipt can
  never satisfy the court vacuously.
  """
  use ExUnit.Case, async: false

  # Excluded from bin/demonstrate's own full-suite row (`mix test --exclude
  # demonstration_court`) so the court does not recurse into itself. The court
  # runs the whole demonstration chain (~8 minutes) so the default 60s ExUnit
  # timeout cannot apply.
  @moduletag :demonstration_court
  @moduletag timeout: :infinity

  @script Path.expand("../bin/demonstrate", __DIR__)
  @receipt Path.expand("../docs/demonstration.md", __DIR__)

  @named_edges [
    "regeneration-core",
    "regeneration-diff-free",
    "ontology-conformance",
    "ontology-conformance-falsifier",
    "store-conformance-ets",
    "store-conformance-dets-negative-controls",
    "chaos-court",
    "policy-failover-court",
    "counterfactual-replay-court",
    "migration-refusal-court",
    "standing-receipts-court",
    "self-hosting-loop-court",
    "full-test-suite"
  ]

  defmodule Receipt do
    @moduledoc false
    def rows(text) do
      text
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "| "))
      |> Enum.reject(
        &(&1 in [
            "| step | command | exit | evidence digest (last line of output) | verdict |",
            "|---|---|---|---|---|"
          ])
      )
      |> Enum.map(fn line ->
        case line |> String.trim("|") |> String.split(" | ") do
          [step, _cmd, exit_code, digest, verdict] ->
            %{
              step: String.trim(step),
              exit: String.trim(exit_code),
              digest: String.trim(digest),
              verdict: String.trim(verdict)
            }

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    end

    def row(text, step) do
      Enum.find(rows(text), &(&1.step == step))
    end

    def pass?(%{verdict: "PASS"}), do: true
    def pass?(_), do: false

    @doc "Refuses a receipt whose rows contain a FAIL, or a SKIP without an explicit reason."
    def valid?(rows) do
      Enum.all?(rows, fn
        %{verdict: "FAIL"} -> false
        %{verdict: "SKIP", digest: d} -> String.starts_with?(d, "SKIP: ")
        %{verdict: "SKIP"} -> false
        _ -> true
      end)
    end
  end

  test "bin/demonstrate exits 0 and the receipt admits every named edge" do
    {output, exit_code} = System.cmd("bash", [@script], cd: Path.expand("..", __DIR__))

    assert exit_code == 0, """
    bin/demonstrate did not pass. Tail of its output:
    #{String.slice(output, -2000, 2000)}
    """

    assert File.exists?(@receipt)
    text = File.read!(@receipt)

    for edge <- @named_edges do
      row = Receipt.row(text, edge)
      assert row, "receipt is missing a row for #{edge}"
      assert Receipt.pass?(row), "row #{edge} is not a PASS row: #{inspect(row)}"
    end

    rows = Receipt.rows(text)
    assert Receipt.valid?(rows), "receipt contains a FAIL row or an unreasoned SKIP"

    # The tla courts and TLC row must exist in some decided form.
    native = Receipt.row(text, "native-tla-court")
    tlc = Receipt.row(text, "tlc-court")

    assert native && tlc

    assert Enum.all?([native, tlc], &(&1.verdict in ["PASS", "SKIP"])),
           "TLA court rows must be PASS or an explicitly reasoned SKIP"

    if tlc.verdict == "SKIP" do
      assert String.contains?(tlc.digest, "java"),
             "a TLC skip must name its reason (missing JVM/binary)"
    end

    assert String.contains?(text, "OVERALL: PASS"),
           "receipt must end with an overall PASS verdict"

    assert String.contains?(text, "## Environment dependencies")
  end

  test "anti-vacuity: the receipt validator refuses a FAIL row" do
    mutant = [%{verdict: "PASS", digest: "ok"}, %{verdict: "FAIL", digest: "boom"}]
    refute Receipt.valid?(mutant)
  end

  test "anti-vacuity: the receipt validator refuses a reasonless SKIP" do
    mutant = [%{verdict: "SKIP", digest: "skipped for some reason"}]
    refute Receipt.valid?(mutant)
  end

  test "anti-vacuity: an empty receipt is not a pass" do
    assert Receipt.rows("no table here") == []
    refute Receipt.row("no table here", "full-test-suite")
  end
end
