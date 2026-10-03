defmodule AshPPlan.Workflow.FacadePurityCourtTest do
  @moduledoc """
  Facade Purity Court (Capability != Implementation). Two scopes:

    * workflow/model/projection layer: must never name a Reactor implementation
      (`Reactor.File`, `Reactor.Req`, `Reactor.Process`, `Ash.Reactor`, `AshDurableReactor`,
      `use Reactor.Step`, `Reactor.Step` module refs).
    * realization layer (allowlist): `AshPPlan.Reactor`, its adapters, the in-repo step
      modules. Only this layer knows implementation names.

  Anti-vacuity: scanned-file counts are floored per scope; the allowlist files must
  contain the names (proving the scanner can see them); mutation cases prove a leak is
  detected in each scope.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @forbidden ~r/\b(Reactor\.(File|Req|Process)\b|Ash\.Reactor\b|AshDurableReactor|use Reactor\b|Reactor\.Step\b)/

  @workflows ["test/support/generated/examples/workflows/**/*.ex"]
  @providers [
    "lib/ash_pplan/generated/workflow/providers/**/*.ex",
    "test/support/generated/examples/providers/**/*.ex"
  ]
  @workflow_layer [
                    "lib/ash_pplan/workflow/**/*.ex",
                    "lib/ash_pplan/generated/workflow/capability_catalog.ex",
                    "lib/ash_pplan/generated/workflow/provider_index.ex",
                    "lib/ash_pplan/providers/registry.ex",
                    "lib/ash_pplan/providers/resolver.ex",
                    "lib/ash_pplan/providers/qualify.ex",
                    "lib/ash_pplan.ex"
                  ] ++ @workflows ++ @providers
  @realization [
    "lib/ash_pplan/reactor.ex",
    "lib/ash_pplan/reactor/**/*.ex",
    "test/support/examples/ultracode/steps.ex",
    "lib/ash_pplan/providers/steps/**/*.ex"
  ]

  defp files(globs) do
    globs
    |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp leaks(globs) do
    for f <- files(globs), File.read!(f) =~ @forbidden, do: Path.relative_to(f, @root)
  end

  test "workflow layer scope is non-vacuous" do
    assert length(files(@workflows)) >= 2
    assert length(files(@providers)) >= 20
    assert length(files(@workflow_layer)) >= 10
  end

  test "App-Purity: lib/ names no application-specific domain, resource, workflow or provider" do
    app_specific =
      ~r/(UltraCode|Ultracode|ultracode|QualifiedFulfillment|qualified_fulfillment|FileRelease|file_release|Shipment|shipment)/

    libs = files(["lib/**/*.ex"])
    assert length(libs) >= 50

    leaks = for f <- libs, File.read!(f) =~ app_specific, do: Path.relative_to(f, @root)
    assert leaks == []

    assert "ultracode" =~ app_specific
    assert "QualifiedFulfillment" =~ app_specific
  end

  test "workflow models and generated workflows name no Reactor implementation" do
    assert leaks(@workflows) == []
  end

  test "generated providers are descriptions, not implementations" do
    assert leaks(@providers) == []
  end

  test "whole workflow/model/projection layer is pure" do
    assert leaks(@workflow_layer) == []
  end

  test "realization layer allowlist does contain implementation names (scanner can see them)" do
    allow = files(@realization)
    assert allow != []
    assert leaks(@realization) != []
    # AshPPlan.Reactor and the in-repo step modules are the knowing layer.
    assert Enum.any?(allow, &(&1 =~ ~r{examples/ultracode/steps\.ex$}))
  end

  test "allowlist and pure scopes are disjoint" do
    assert MapSet.disjoint?(MapSet.new(files(@realization)), MapSet.new(files(@workflow_layer)))
  end

  test "mutation: the scanner detects each forbidden name" do
    for leak <- [
          "step Reactor.File.Step.WriteFile",
          "Reactor.Req.Step.Request",
          "Reactor.Process.Step",
          "use Ash.Reactor",
          "AshDurableReactor.run()",
          "use Reactor.Step",
          "{Reactor.Step, x}"
        ] do
      assert leak =~ @forbidden, leak
    end

    refute "alias AshPPlan.Capability" =~ @forbidden
    refute "Reactor.t()" =~ @forbidden
  end

  test "mutation: a leak injected into a pure-scope file is reported" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "facade_mut_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    clean = Path.join(dir, "clean.ex")
    dirty = Path.join(dir, "dirty.ex")
    File.write!(clean, "defmodule C do\nend\n")
    File.write!(dirty, "defmodule D do\n  use Reactor.Step\nend\n")

    found = for f <- [clean, dirty], File.read!(f) =~ @forbidden, do: Path.basename(f)
    assert found == ["dirty.ex"]
  end
end
