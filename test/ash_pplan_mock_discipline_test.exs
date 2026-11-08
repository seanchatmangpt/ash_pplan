# SPDX-FileCopyrightText: 2026 ash_pplan contributors <https://github.com/seanchatmangpt/ash_pplan/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPPlan.MockDisciplineTest do
  @moduledoc """
  The fleet mock-discipline court, ported from ash_a2a
  (`test/ash_a2a_mock_discipline_test.exs` + its AST scanner
  `lib/ash_a2a/chicago/collaborators/mock_scan.ex`).

  The fleet gate regex is:

      (use|import) +(Mox|Mimic|Patch)\b|(Mox|Mimic|Patch)\.|:meck\.|mockall|MagicMock

  run with `grep -rnE --include=*.ex --include=*.exs` over `lib/` and `test/`.
  The naive reading -- "exit 1 = clean" -- is false by design: this court's
  own scanner quotes banned tokens verbatim in docstrings (the ggen
  precedent: well-formed test files are hits against themselves).

  ## Audit (this tree, pre-port) -- zero raw grep hits

  The fleet regex run over `lib/` + `test/` returned zero hits on this tree
  before the port: no Mox/Mimic/Patch/:meck/mockall/MagicMock token exists
  anywhere in `lib/` or `test/`. Lawful external-system fakes in this repo
  (hand-written real implementations of behaviours) are not banned-token
  positions and need no allowlist entry.

  ## The gate (three assertions, each fails closed)

    1. the fleet regex has teeth: run against a real temp file containing
       `use Mox`, grep must match (exit 0) -- a regex that silently stopped
       matching must fail this test, not the next incident;
    2. the AST scan over `lib/` + `test/` is `:clean` with files scanned > 0
       -- zero code-position violations, unparseable source fails closed;
    3. every raw grep hit lives in the allowlist of disclosure files
       (keyed by file, not line). A banned token in any NEW file turns this
       red and forces a reviewed allowlist extension.

  Red/green proof: a temp-copy `Mox.defmock` injection into `lib/` flips
  assertions 2 and 3 red; byte-exact restore returns green.
  """

  use ExUnit.Case, async: true

  @regex ~S[(use|import) +(Mox|Mimic|Patch)\b|(Mox|Mimic|Patch)\.|:meck\.|mockall|MagicMock]

  # Files whose docstrings/comments quote banned tokens. Keyed by path
  # (relative to repo root), not line: prose shifts, the disclosure files do
  # not. Extending this list is a reviewed admission.
  @disclosure_files [
    "lib/ash_pplan/chicago/collaborators/mock_scan.ex",
    # This file's own moduledoc quotes the banned tokens to document them.
    "test/ash_pplan_mock_discipline_test.exs"
  ]

  test "fleet mock-discipline gate: AST-clean tree, regex with teeth, prose hits allowlisted" do
    # 1. The regex has teeth -- real grep against a real violating file.
    tmp = System.tmp_dir!()
    path = Path.join(tmp, "ash_pplan-mock-teeth-#{System.unique_integer([:positive])}.exs")
    File.write!(path, "defmodule T do\n  use Mox\nend\n")

    teeth = System.cmd("grep", ["-rnE", @regex, path], stderr_to_stdout: true)
    File.rm(path)

    assert {_, exit_teeth} = teeth
    assert exit_teeth == 0, "fleet regex failed to match a real `use Mox` (exit #{exit_teeth})"

    # 2. Code positions: the AST law over lib/ + test/.
    scan = AshPPlan.Chicago.Collaborators.MockScan.scan(root: File.cwd!(), dirs: ["lib", "test"])

    assert scan.files > 0, "AST scan saw no files -- gate vacuous"
    assert scan.violations == [], inspect(scan.violations, pretty: true)
    assert scan.unparseable == [], inspect(scan.unparseable, pretty: true)
    assert scan.outcome == :clean

    # 3. Raw fleet grep over the tree: every hit must be a disclosure-file
    #    prose hit, never a new file.
    {out, exit_grep} =
      System.cmd("grep", ["-rnE", @regex, "--include=*.ex", "--include=*.exs", "lib", "test"],
        stderr_to_stdout: true
      )

    assert exit_grep in [0, 1], "grep errored (exit #{exit_grep}): #{out}"

    hits =
      out
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 3) do
          [file, lineno, _text] -> {file, String.to_integer(lineno)}
          _ -> raise("unparseable grep line: #{inspect(line)}")
        end
      end)

    offending =
      hits
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.reject(&(&1 in @disclosure_files))

    assert offending == [],
           "banned tokens outside the disclosure allowlist: #{inspect(offending)}" <>
             "\nraw hits:\n#{out}"
  end
end
