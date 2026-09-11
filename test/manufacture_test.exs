defmodule AshPPlan.ManufactureTest do
  use ExUnit.Case, async: false

  @pack Path.expand("../priv/ggen/ash-pplan-pack", __DIR__)

  @projections {
    "projection_catalog.ex.eex",
    Path.expand("../lib/ash_pplan/generated/projection_catalog.ex", __DIR__)
  }

  @plans {
    "plan_catalog.ex.eex",
    Path.expand("../lib/ash_pplan/generated/plan_catalog.ex", __DIR__)
  }

  test "ggen_igniter regenerates every checked-in projection from the canonical ontology" do
    for {template_name, checked_in_path} <- [@projections, @plans] do
      output =
        Path.join(
          System.tmp_dir!(),
          "ash_pplan_#{template_name}_#{System.unique_integer([:positive, :monotonic])}.ex"
        )

      Mix.Task.reenable("ggen_igniter.sync")

      Mix.Task.run("ggen_igniter.sync", [
        "--pack-dir",
        @pack,
        "--template",
        Path.join([@pack, "templates", template_name]),
        "--engine",
        "oxigraph",
        "--out",
        output
      ])

      generated = output |> File.read!() |> Code.format_string!() |> IO.iodata_to_binary()
      checked_in = checked_in_path |> File.read!() |> Code.format_string!() |> IO.iodata_to_binary()

      assert generated == checked_in

      File.rm(output)
    end
  end
end
