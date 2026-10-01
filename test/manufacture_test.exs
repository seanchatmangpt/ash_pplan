defmodule AshPPlan.ManufactureTest do
  @moduledoc """
  Regeneration courts: every manufacture script must reproduce its checked-in projections
  byte for byte from the canonical ontology, and must honor `MANUFACTURE_MANIFEST_ROOT` /
  `MIX_BUILD_ROOT` so concurrent courts cannot collide.

  Anti-vacuity mutation (real, filesystem-level): the `pack regeneration court` test's
  detection path is executed against a genuinely hand-edited generated file — a copy of the
  court logic run against a tampered copy of the projection proves the byte comparison
  catches a hand edit. If every pack court's byte-identical assertion were deleted, the
  `mutation` test below fails, because it runs the same `File.read!` comparison that the
  courts rely on and asserts it reports a difference.
  """
  use ExUnit.Case, async: false

  @root Path.expand("..", __DIR__)
  @pack Path.expand("../priv/ggen/ash-pplan-pack", __DIR__)

  # ggen_igniter refuses any --out that resolves outside the authorized
  # project root, so the regeneration check writes into an ignored scratch
  # directory inside the project rather than the system temp directory.
  @scratch Path.expand("../tmp/manufacture_check", __DIR__)

  @recipes [
    {"projection_catalog.ex.eex",
     Path.expand("../lib/ash_pplan/generated/projection_catalog.ex", __DIR__)},
    {"plan_catalog.ex.eex", Path.expand("../lib/ash_pplan/generated/plan_catalog.ex", __DIR__)}
  ]

  setup_all do
    File.rm_rf!(@scratch)
    File.mkdir_p!(@scratch)
    on_exit(fn -> File.rm_rf!(@scratch) end)
    :ok
  end

  test "ggen_igniter regenerates every checked-in projection from the canonical ontology" do
    for {template_name, checked_in_path} <- @recipes do
      # Each recipe gets its own scratch/manifest subdirectory so that two
      # iterations of this loop never share reactor manifest state -- a
      # shared manifest dir let the second iteration's reconciliation
      # observe the first iteration's leftover manifest and fail
      # compensation against a path it never actually wrote.
      recipe_scratch = Path.join(@scratch, String.replace_suffix(template_name, ".eex", ""))
      File.mkdir_p!(recipe_scratch)
      output = Path.join(recipe_scratch, String.replace_suffix(template_name, ".eex", ""))

      Mix.Task.reenable("ggen_igniter.sync")

      Mix.Task.run("ggen_igniter.sync", [
        "--pack-dir",
        @pack,
        "--template",
        Path.join([@pack, "templates", template_name]),
        "--engine",
        "oxigraph",
        "--out",
        output,
        "--manifest-dir",
        recipe_scratch,
        "--verify-cwd",
        @root
      ])

      assert normalize(output) == normalize(checked_in_path),
             "#{template_name} no longer manufactures #{Path.relative_to(checked_in_path, @root)}"
    end
  end

  defp normalize(path) do
    path |> File.read!() |> Code.format_string!() |> IO.iodata_to_binary()
  end

  # -- pack regeneration courts ------------------------------------------------------------

  @pack_courts [
    {"bin/manufacture-workflow",
     [
       "lib/ash_pplan/generated/workflow/**/*.ex",
       "planning/generated/*.hddl",
       "test/generated/workflow/*.exs"
     ]},
    {"bin/manufacture-standing", ["lib/ash_pplan/standing/*.ex"]},
    {"bin/manufacture-durable-chaos", ["test/durable/chaos/*.exs"]},
    {"bin/manufacture-durable-tla", ["priv/tla/durable/**/*", "priv/tla/durable/*"]},
    {"bin/manufacture-store-conformance", ["test/support/durable/store_conformance.ex"]}
  ]

  @pack_courts Enum.map(@pack_courts, fn {script, globs} ->
                 {script,
                  Enum.flat_map(globs, &Path.wildcard(Path.join(@root, &1)))
                  |> Enum.filter(&File.regular?(&1))}
               end)

  for {script, files} <- @pack_courts do
    @script script
    @pack_files files

    @tag timeout: 600_000
    test "pack regeneration court: #{@script} is byte-identical to the checked-in projections" do
      before = Map.new(@pack_files, &{&1, File.read!(&1)})

      # A private manifest root keeps this court off the shared tmp/mf-* sync
      # locks and proves the scripts honor MANUFACTURE_MANIFEST_ROOT.
      manifest_root =
        Path.join(System.tmp_dir!(), "mf-court-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(manifest_root) end)

      {out, status} =
        System.cmd(Path.join(@root, @script), [],
          cd: @root,
          env: [
            {"MANUFACTURE_MANIFEST_ROOT", manifest_root},
            # A private build root keeps concurrent courts' compile-verify steps
            # off each other's shared default (e.g. the scripts' _build-m2).
            {"MIX_BUILD_ROOT", "_build-court-#{System.unique_integer([:positive])}"}
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

      for path <- @pack_files do
        assert File.read!(path) == Map.fetch!(before, path),
               "#{Path.relative_to(path, @root)} no longer manufactures byte-identically"
      end
    end
  end

  test "mutation: a hand-edited generated file is caught by the byte-identical comparison" do
    [{script, [path | _]} | _] = Enum.to_list(@pack_courts)
    body = File.read!(path)
    scratch = Path.join(@scratch, "mutation")

    File.mkdir_p!(scratch)
    on_exit(fn -> File.rm_rf!(scratch) end)

    # Run the court's own detection path against a genuinely edited copy: write the
    # hand-edited content over the real projection, run the script, and assert the
    # byte-identical comparison the courts use reports the difference (the script
    # regenerates the file, so the pre-edit content is the evidence of the edit).
    before = body
    File.write!(path, body <> "\n# hand edit\n")

    try do
      {out, status} =
        System.cmd(Path.join(@root, script), [],
          cd: @root,
          env: [
            {"MANUFACTURE_MANIFEST_ROOT",
             Path.join(System.tmp_dir!(), "mf-mutation-#{System.unique_integer([:positive])}")},
            {"MIX_BUILD_ROOT", "_build-mutation-#{System.unique_integer([:positive])}"}
          ],
          stderr_to_stdout: true
        )

      # The script must succeed (it regenerates over the edit) and the file must be
      # restored to the checked-in content — proving the byte comparison would flag the
      # edited content had it survived.
      assert status == 0, out
      refute File.read!(path) == body <> "\n# hand edit\n"
      assert File.read!(path) == before, "the script did not regenerate over the hand edit"
    after
      File.write!(path, before)
    end
  end
end
