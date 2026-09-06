defmodule AshPPlan.ManufactureTest do
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
      output = Path.join(@scratch, String.replace_suffix(template_name, ".eex", ""))

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
        @scratch,
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
end
