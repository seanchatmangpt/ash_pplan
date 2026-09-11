defmodule AshPPlan.ManufactureTest do
  use ExUnit.Case, async: false

  @generated Path.expand("../lib/ash_pplan/generated/projection_catalog.ex", __DIR__)
  @pack Path.expand("../priv/ggen/ash-pplan-pack", __DIR__)

  test "ggen_igniter regenerates the checked-in projection from the canonical ontology" do
    output =
      Path.join(
        System.tmp_dir!(),
        "ash_pplan_projection_#{System.unique_integer([:positive, :monotonic])}.ex"
      )

    Mix.Task.reenable("ggen_igniter.sync")

    Mix.Task.run("ggen_igniter.sync", [
      "--pack-dir",
      @pack,
      "--engine",
      "oxigraph",
      "--out",
      output
    ])

    generated = output |> File.read!() |> Code.format_string!() |> IO.iodata_to_binary()
    checked_in = @generated |> File.read!() |> Code.format_string!() |> IO.iodata_to_binary()

    assert generated == checked_in

    File.rm(output)
  end
end
