defmodule AshPPlan.Workflow.FacadePurityCourtTest do
  @moduledoc """
  Facade Purity Court: application-facing workflow code (DSL workflows, generated workflow
  models, examples) must never name a Reactor extension or step implementation. Those names may
  appear only in providers, realization adapters, `AshPPlan.Reactor` and generated provider
  infrastructure. Falsified by the mutation case, which proves the scanner detects a leak.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @forbidden ~r/\b(Reactor\.(File|Req|Process)\b|Ash\.Reactor\b|AshDurableReactor|use Reactor\b)/
  @facing ["lib/ash_pplan/generated/workflow/workflows", "lib/ash_pplan/examples"]

  defp facing_files do
    @facing
    |> Enum.flat_map(&Path.wildcard(Path.join([@root, &1, "**", "*.ex"])))
    |> Enum.reject(&String.contains?(&1, "/steps"))
  end

  test "application-facing modules reference no Reactor implementation" do
    assert length(facing_files()) >= 2

    leaks =
      for file <- facing_files(),
          File.read!(file) =~ @forbidden,
          do: Path.relative_to(file, @root)

    assert leaks == []
  end

  test "mutation: the scanner detects a leak" do
    assert "defmodule W do\n  step Reactor.File.Step.WriteFile\nend" =~ @forbidden
    assert "alias AshPPlan.Capability" =~ @forbidden == false
  end
end
