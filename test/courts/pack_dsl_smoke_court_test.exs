defmodule AshPPlan.Courts.PackDslSmokeCourtTest do
  @moduledoc """
  Smoke-level pack court for `priv/ggen/ash-pplan-dsl-pack/`: the pack's
  `bin/manufacture-dsl` script must render the project-local Spark DSL
  surface (`lib/ash_pplan/dsl.ex`, `lib/ash_pplan/dsl/*.ex`,
  `lib/ash_pplan/dsl/pplan/*.ex`) byte-identically to the checked-in
  projections. Modeled on the `@pack_courts` entry in
  `test/manufacture_test.exs`, as a standalone court so the DSL pack has its
  own named receipt.

  Honors MANUFACTURE_MANIFEST_ROOT / private MIX_BUILD_ROOT like every other
  pack-regeneration court; build roots are leases and are deleted on exit.
  Select-only court: no DO authority.
  """

  use ExUnit.Case, async: false

  @repo Path.expand("../..", __DIR__)
  @script "priv/ggen/ash-pplan-dsl-pack/bin/manufacture-dsl"

  @pack_files [
    "lib/ash_pplan/dsl.ex",
    "lib/ash_pplan/dsl/pplan.ex",
    "lib/ash_pplan/dsl/pplan/lift.ex"
  ]

  @tag timeout: 900_000
  test "manufacture-dsl renders lib/ash_pplan/dsl* byte-identical" do
    before = Map.new(@pack_files, fn rel -> {rel, File.read!(Path.join(@repo, rel))} end)

    # A private manifest root keeps this court off the shared tmp/mf sync locks
    # and proves the script honors MANUFACTURE_MANIFEST_ROOT.
    manifest_root =
      Path.join(
        System.tmp_dir!(),
        "mf-court-dsl-#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}"
      )

    # Build roots are leases: the unique-per-run root must not outlive the run.
    build_root =
      "_build-court-dsl-#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}"

    on_exit(fn ->
      File.rm_rf(manifest_root)
      File.rm_rf(Path.join(@repo, build_root))
    end)

    {out, status} =
      System.cmd(Path.join(@repo, @script), [],
        cd: @repo,
        env: [
          {"MANUFACTURE_MANIFEST_ROOT", manifest_root},
          {"MIX_BUILD_ROOT", build_root}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, out

    # Scripts write "$root-<recipe>" manifest dirs; the root itself may not be mkdir'd.
    used =
      manifest_root
      |> Path.dirname()
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, Path.basename(manifest_root)))

    assert used != [], "script ignored MANUFACTURE_MANIFEST_ROOT"

    for rel <- @pack_files do
      path = Path.join(@repo, rel)

      assert File.read!(path) == Map.fetch!(before, rel),
             "#{rel} no longer manufactures byte-identically"
    end
  end
end
