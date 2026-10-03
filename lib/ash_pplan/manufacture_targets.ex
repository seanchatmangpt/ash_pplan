defmodule AshPPlan.ManufactureTargets do
  @moduledoc """
  Single source of truth for the ggen_igniter manufacture manifest.

  `bin/manufacture` renders this module's data; the release contract court
  (`test/release_contract_test.exs`) diffs and marker-checks the same data, so
  the manifest cannot drift between the manufacturer and its courts.

  All paths are `@root`-relative.
  """

  @root Path.expand("../..", __DIR__)

  @doc "Repository root, for consumers resolving the relative paths."
  @spec root() :: String.t()
  def root, do: @root

  @doc """
  One entry per manufacture product. `template` names the ggen_igniter
  template/pack source; `out` is the `@root`-relative output path; `module`
  is the Elixir module the projection defines. The provider and court
  entries are per-example fan-outs (one per entry in `providers/0`).
  """
  @spec targets() :: [%{template: String.t(), out: String.t(), module: module() | String.t()}]
  def targets do
    projection_catalog =
      %{
        template: "projection_catalog",
        out: "lib/ash_pplan/catalog/projection_catalog.ex",
        module: AshPPlan.Catalog.Projection
      }

    plan_catalog =
      %{
        template: "plan_catalog",
        out: "lib/ash_pplan/catalog/plan_catalog.ex",
        module: AshPPlan.Catalog.Plan
      }

    capability_catalog = %{
      template: "capability_catalog",
      out: "lib/ash_pplan/workflow/capability_catalog.ex",
      module: AshPPlan.Workflow.CapabilityCatalog
    }

    provider_index = %{
      template: "provider_index",
      out: "lib/ash_pplan/providers/index.ex",
      module: AshPPlan.Providers.Index
    }

    provider_targets =
      for name <- providers() do
        %{
          template: "provider/#{name}",
          out: "lib/ash_pplan/providers/#{name}.ex",
          module: AshPPlan.Providers
        }
      end

    court_targets =
      for name <- providers() do
        %{
          template: "court/#{name}",
          out: "test/courts/providers/#{name}_provider_court_test.exs",
          module: AshPPlan.Examples.ProviderCourt
        }
      end

    [projection_catalog, plan_catalog, capability_catalog, provider_index] ++
      provider_targets ++ court_targets
  end

  @doc """
  Example-provider names the per-each provider and court targets fan over.
  """
  @spec providers() :: [String.t()]
  def providers do
    ~w(a2a domain durability durable_dispatch event_state file network observation process remote scheduling)
  end

  @doc """
  The directories/paths the release gate diffs against HEAD after
  manufacture. Replaces the old four-dir `lib/ash_pplan/generated` list.
  """
  @spec generated_dirs() :: [String.t()]
  def generated_dirs do
    [
      "lib/ash_pplan/catalog",
      "lib/ash_pplan/providers",
      "lib/ash_pplan/workflow/capability_catalog.ex",
      "test/courts/providers",
      "test/support/examples",
      "planning/examples"
    ]
  end
end
