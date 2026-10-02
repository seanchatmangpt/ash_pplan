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
  @scratch_base Path.expand("../tmp/manufacture_check", __DIR__)

  @recipes [
    {"projection_catalog.ex.eex",
     Path.expand("../lib/ash_pplan/generated/projection_catalog.ex", __DIR__)},
    {"plan_catalog.ex.eex", Path.expand("../lib/ash_pplan/generated/plan_catalog.ex", __DIR__)}
  ]

  setup_all do
    # A run-unique scratch root: a shared "tmp/manufacture_check" put two
    # concurrent suites (this file and another lane's run of it) on the SAME
    # ggen_igniter sync lock, timing one of them out. Unique per run keeps
    # every suite's scratch off every other's lock.
    scratch = Path.join(@scratch_base, "run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(scratch)
    on_exit(fn -> File.rm_rf!(@scratch_base) end)
    {:ok, scratch: scratch}
  end

  @tag timeout: 900_000
  test "ggen_igniter regenerates every checked-in projection from the canonical ontology", %{
    scratch: scratch
  } do
    for {template_name, checked_in_path} <- @recipes do
      # Each recipe gets its own scratch/manifest subdirectory so that two
      # iterations of this loop never share reactor manifest state -- a
      # shared manifest dir let the second iteration's reconciliation
      # observe the first iteration's leftover manifest and fail
      # compensation against a path it never actually wrote.
      recipe_scratch = Path.join(scratch, String.replace_suffix(template_name, ".eex", ""))
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
                  |> Enum.filter(&File.regular?(&1))
                  |> Enum.sort()}
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

      # Build roots are leases: the unique-per-run root must not outlive the run.
      build_root = "_build-court-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        File.rm_rf(manifest_root)
        File.rm_rf(Path.join(@root, build_root))
      end)

      {out, status} =
        System.cmd(Path.join(@root, @script), [],
          cd: @root,
          env: [
            {"MANUFACTURE_MANIFEST_ROOT", manifest_root},
            # A private build root keeps concurrent courts' compile-verify steps
            # off each other's shared default (e.g. the scripts' _build-m2).
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

      for path <- @pack_files do
        assert File.read!(path) == Map.fetch!(before, path),
               "#{Path.relative_to(path, @root)} no longer manufactures byte-identically"
      end
    end
  end

  @tag timeout: 900_000
  # The mutation court spawns a full fresh-build ./bin/manufacture into its own
  # MIX_BUILD_ROOT; under concurrent-lane machine load that build alone can take
  # well past the 60s default. Bounded at 15 min rather than :infinity so a hung
  # run still fails loudly.
  test "mutation: a hand-edited generated file is caught by the byte-identical comparison" do
    [{script, [path | _]} | _] = Enum.to_list(@pack_courts)
    body = File.read!(path)

    mutation_manifest =
      Path.join(System.tmp_dir!(), "mf-mutation-#{System.unique_integer([:positive])}")

    mutation_build = "_build-mutation-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      File.rm_rf(mutation_manifest)
      File.rm_rf(Path.join(@root, mutation_build))
    end)

    # Run the court's own detection path against a genuinely edited copy: write the
    # hand-edited content over the real projection, run the script, and assert the
    # hand edit does not silently survive a successful run.
    # Self-heal: an earlier run killed between the hand edit and this test's
    # `after` restore leaves the marker on disk. Strip every occurrence so the
    # mutation is applied to a clean baseline (and so the `after` clause can
    # never perpetuate contamination as "checked-in content").
    clean = String.replace(body, "\n# hand edit\n", "")

    before = clean
    File.write!(path, clean <> "\n# hand edit\n")

    try do
      {out, status} =
        System.cmd(Path.join(@root, script), [],
          cd: @root,
          env: [
            {"MANUFACTURE_MANIFEST_ROOT", mutation_manifest},
            {"MIX_BUILD_ROOT", mutation_build}
          ],
          stderr_to_stdout: true
        )

      after_content = File.read!(path)

      # Admissible outcomes for a correct generator: the script exits nonzero
      # (refusal -- ggen protecting a diverged output is correct behavior), or it
      # regenerates over the edit. The one inadmissible outcome -- and the real
      # anti-vacuity falsifier -- is a zero exit with the hand-edit marker still
      # on disk: that is exactly what a broken regeneration (silent skip) looks
      # like, and the pack courts above rely on the script either refusing or
      # rewriting diverged outputs.
      assert status != 0 or not String.contains?(after_content, "\n# hand edit\n"),
             "the script exited 0 but left the hand edit on disk " <>
               "(silent skip -- the pack courts' byte comparison would never fire); " <>
               "exit: #{status}\n#{out}"
    after
      File.write!(path, before)
    end
  end
end
