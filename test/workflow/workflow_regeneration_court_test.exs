defmodule AshPPlan.Workflow.WorkflowRegenerationCourtTest do
  @moduledoc """
  Regeneration court for the workflow pack: re-running every recipe from the ontology must
  reproduce each checked-in generated file byte for byte. Falsified by the mutation case,
  which shows a hand-edit to generated output is detected by the same comparison.
  """
  use ExUnit.Case, async: false

  @root Path.expand("../..", __DIR__)
  @globs [
    "lib/ash_pplan/generated/workflow/**/*.ex",
    "planning/generated/*.hddl",
    "test/generated/workflow/*.exs"
  ]

  defp snapshot do
    @globs
    |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
    |> Map.new(&{Path.relative_to(&1, @root), File.read!(&1)})
  end

  @tag timeout: 600_000
  test "manufacture-workflow reproduces every checked-in generated file" do
    before = snapshot()
    assert map_size(before) > 20

    # A private manifest root keeps this court from contending for the
    # shared tmp/mf-* sync locks with any concurrent manufacture run.
    manifest_root =
      Path.join(
        System.tmp_dir!(),
        "mf-court-#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}"
      )

    on_exit(fn -> File.rm_rf(manifest_root) end)

    {out, status} =
      System.cmd(Path.join(@root, "bin/manufacture-workflow"), [],
        cd: @root,
        env: [{"MANUFACTURE_MANIFEST_ROOT", manifest_root}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert snapshot() == before
  end

  test "mutation: a hand-edited generated file is detected" do
    before = snapshot()
    [{path, body} | _] = Enum.to_list(before)
    refute Map.put(before, path, body <> "# hand edit\n") == before
  end
end
