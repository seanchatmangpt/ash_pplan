defmodule AshPPlan.MirrorSim.RunnerTest do
  use ExUnit.Case, async: false

  alias AshPPlan.MirrorSim.Runner

  doctest AshPPlan.MirrorSim.Runner

  defp step(attrs) do
    Map.merge(
      %{
        file: "test/mirror_sim/a_test.exs",
        phase: :area,
        cmd: "mix test",
        exit: 0,
        tests: 1,
        failures: 0,
        killed: 0,
        survived: 0,
        missing: []
      },
      Map.new(attrs)
    )
  end

  test "standing is fail-closed and flips on each defect class" do
    mut = step(phase: :mutants, killed: 3)
    assert Runner.standing([step([]), mut]) == "ALIVE"
    assert Runner.standing([step([]), %{mut | survived: 1}]) == "PARTIAL_ALIVE"
    assert Runner.standing([step([]), %{mut | missing: ["X.y/1"]}]) == "PARTIAL_ALIVE"
    assert Runner.standing([step([])]) == "PARTIAL_ALIVE"
    assert Runner.standing([step([]), step(exit: 1, failures: 2)]) == "PARTIAL"
    assert Runner.standing([step(exit: 1)]) == "BLOCKED"
    assert Runner.standing([]) == "UNVERIFIED"
  end

  test "render puts a closed-vocabulary Standing line right after the H1 with SHA and counts" do
    steps = [step([]), step(phase: :mutants, killed: 4, survived: 1, missing: ["M.f/0"])]

    [h1, "", standing | _] =
      md = String.split(Runner.render(%{sha: "abc123", steps: steps}), "\n")

    assert h1 == "# mirror-sim abc123"
    assert "Standing: " <> value = standing
    assert value in Runner.standings()
    text = Enum.join(md, "\n")
    assert text =~ "Subject SHA: abc123"
    assert text =~ "Mutants killed: 4"
    assert text =~ "Mutants survived: 1"
    assert text =~ "- MISSING M.f/0"
  end

  test "write_receipt persists receipts/mirror-sim-<sha>.md on disk" do
    root = Path.join(System.tmp_dir!(), "mirror_runner_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, path, _} = Runner.write_receipt(root, [step([])])
    assert Path.dirname(path) == Path.join(root, "receipts")
    assert Path.basename(path) =~ ~r/^mirror-sim-.+\.md$/
    assert File.read!(path) =~ "Standing: "
  end

  test "classify routes mutation, parity, coverage and area files" do
    assert Runner.classify("test/mirror_sim/mutants_runtime_test.exs") == :mutants
    assert Runner.classify("test/mirror_sim/x_test.exs") == :area
  end
end
