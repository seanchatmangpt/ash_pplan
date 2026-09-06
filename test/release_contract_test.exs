defmodule AshPPlan.ReleaseContractTest do
  @moduledoc """
  Guards the release's own claims.

  Version identity, the admitted projection standings, and the manufactured
  catalogs are all things the release states in prose. Each is asserted here so
  drift fails the build instead of shipping.
  """

  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  # ontology/shapes.ttl admits exactly these standings; bin/conform enforces
  # that at the semantic boundary and this mirrors it at the Elixir boundary.
  @admitted_standings ~w(reuse gap extension)

  describe "version identity" do
    test "the runtime surface reports the packaged version" do
      assert AshPPlan.version() == Mix.Project.config()[:version]
    end

    test "the changelog documents the packaged version first" do
      [_heading, first_release | _] =
        @root |> Path.join("CHANGELOG.md") |> File.read!() |> String.split("\n## ")

      assert String.starts_with?(first_release, AshPPlan.version() <> " ")
    end

    test "the canonical ontology carries the packaged release version" do
      ontology = @root |> Path.join("ontology.ttl") |> File.read!()

      assert [_, version] = Regex.run(~r/owl:versionInfo "([^"]+)"/, ontology)
      assert version == AshPPlan.version()
    end

    test "the producer lock records the packaged release" do
      lock = @root |> Path.join("ecosystem.lock.toml") |> File.read!()

      assert lock =~ ~s(release = "v#{AshPPlan.version()}")
    end
  end

  describe "manufactured projection catalog" do
    test "every projection carries an admitted standing" do
      for projection <- AshPPlan.projections() do
        assert projection.status in @admitted_standings,
               "projection #{projection.source} has unadmitted standing #{projection.status}"
      end
    end

    test "every projection is uniquely addressable by source IRI" do
      sources = Enum.map(AshPPlan.projections(), & &1.source)

      assert sources == Enum.uniq(sources)
    end

    test "every projection is complete" do
      for projection <- AshPPlan.projections() do
        for key <- [:source, :target, :primitive, :owner, :role, :status] do
          value = Map.fetch!(projection, key)

          assert is_binary(value) and value != "",
                 "projection #{projection.source} has an empty #{key}"
        end
      end
    end

    test "the persistence gap is still admitted as a gap, not quietly closed" do
      assert [%{status: "gap", owner: "consumer"}] = AshPPlan.projections_for(:persistence)
    end

    test "ash_pplan only owns the projections it declares as extensions" do
      owned = Enum.filter(AshPPlan.projections(), &(&1.owner == "ash_pplan"))

      assert owned != []
      assert Enum.all?(owned, &(&1.status == "extension"))

      # Semantic execution and its evidence are the extensions this release
      # claims; everything else must stay owned by an existing runtime.
      roles = owned |> Enum.map(& &1.role) |> MapSet.new()
      assert MapSet.subset?(MapSet.new(["execution", "evidence"]), roles)
    end
  end

  describe "manufactured plan catalog" do
    test "every cataloged plan compiles against handlers for its own steps" do
      for plan <- AshPPlan.plans() do
        handlers = Map.new(plan.steps, &{&1.iri, AshPPlan.ReleaseContractTest.PassThrough})

        assert {:ok, _reactor} = AshPPlan.compile_plan(plan.iri, handlers),
               "cataloged plan #{plan.iri} does not compile"
      end
    end

    test "every predecessor references a step of the same plan" do
      for plan <- AshPPlan.plans() do
        known = MapSet.new(plan.steps, & &1.iri)

        for step <- plan.steps, predecessor <- step.predecessors do
          assert MapSet.member?(known, predecessor),
                 "step #{step.iri} is preceded by #{predecessor}, which is outside its plan"
        end
      end
    end

    test "the catalog is non-empty, so the manufacture gate cannot pass vacuously" do
      assert AshPPlan.plans() != []
      assert AshPPlan.projections() != []
    end

    test "every projection declared in the ontology reaches the catalog" do
      # Every generated-catalog assertion quantifies over rows that survived the
      # SPARQL gate, so none of them can notice a row the gate dropped. Gate 010
      # requires all seven fields, so one missing field silently removes a
      # projection. This counts the declarations at the source instead.
      declared =
        @root
        |> Path.join("ontology.ttl")
        |> File.read!()
        |> then(&Regex.scan(~r/^ap:[\w-]+ a ap:Projection\b/m, &1))
        |> length()

      assert declared > 0
      assert length(AshPPlan.projections()) == declared
    end

    test "every plan and step declared in the ontology reaches the catalog" do
      ontology = @root |> Path.join("ontology.ttl") |> File.read!()

      declared_plans = Regex.scan(~r/^ap:[\w-]+ a p-plan:Plan\b/m, ontology) |> length()
      declared_steps = Regex.scan(~r/^ap:[\w-]+ a p-plan:Step\b/m, ontology) |> length()

      assert length(AshPPlan.plans()) == declared_plans
      assert AshPPlan.plans() |> Enum.flat_map(& &1.steps) |> length() == declared_steps
    end
  end

  describe "release gate" do
    test "the check alias declares the environment it needs" do
      # mix check runs mix test. Without a preferred env the alias refuses in
      # :dev and the gate passes over zero tests.
      assert AshPPlan.MixProject.cli()[:preferred_envs][:check] == :test
    end

    test "the check alias still runs both the formatter and the tests" do
      assert ["format --check-formatted", "test"] =
               Mix.Project.config()[:aliases][:check]
    end
  end

  describe "producer identities" do
    setup do
      %{
        lock: @root |> Path.join("ecosystem.lock.toml") |> File.read!(),
        ci: @root |> Path.join(".github/workflows/ci.yml") |> File.read!()
      }
    end

    test "CI pins the ggen-ecosystem digest recorded in the producer lock", %{
      lock: lock,
      ci: ci
    } do
      [_, digest] = Regex.run(~r/digest = "(sha256:[0-9a-f]{64})"/, lock)

      assert ci =~ digest,
             "CI does not qualify the ggen-ecosystem digest recorded in ecosystem.lock.toml"
    end

    test "CI pins the SHACL toolchain recorded in the producer lock", %{lock: lock, ci: ci} do
      [_, rdflib] = Regex.run(~r/rdflib = "([\d.]+)"/, lock)
      [_, pyshacl] = Regex.run(~r/pyshacl = "([\d.]+)"/, lock)

      assert ci =~ "rdflib==#{rdflib}"
      assert ci =~ "pyshacl==#{pyshacl}"
    end

    test "CI runs every gate the release gate claims", %{ci: ci} do
      for gate <- [
            "./bin/conform",
            "./bin/conform-falsify",
            "mix check",
            "./bin/manufacture",
            "git diff --exit-code -- lib/ash_pplan/generated",
            "./bin/verify-package",
            "./bin/receipt"
          ] do
        assert ci =~ gate, "CI does not run the release gate step: #{gate}"
      end
    end

    test "the resolved dependency tree matches the versions the lock claims to have observed" do
      lock = @root |> Path.join("mix.lock") |> File.read!()
      ecosystem = @root |> Path.join("ecosystem.lock.toml") |> File.read!()

      for dependency <- ~w(ash reactor ash_oban) do
        [_, observed] =
          Regex.run(~r/^\[#{dependency}\]\nversion_observed = "([^"]+)"/m, ecosystem)

        assert lock =~ ~s("#{dependency}": {:hex, :#{dependency}, "#{observed}"),
               "ecosystem.lock.toml observes #{dependency} #{observed}, mix.lock resolves something else"
      end
    end

    test "the manufacture and conformance entrypoints are executable" do
      for script <-
            ~w(bin/manufacture bin/conform bin/conform-falsify bin/receipt bin/verify-package) do
        path = Path.join(@root, script)

        assert File.exists?(path), "#{script} is missing"
        assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
        assert Bitwise.band(mode, 0o111) != 0, "#{script} is not executable"
      end
    end
  end

  describe "semantic authority" do
    test "the pack ontology remains a symlink to the canonical source" do
      pack_ontology = Path.join(@root, "priv/ggen/ash-pplan-pack/ontology.ttl")

      assert {:ok, target} = File.read_link(pack_ontology)
      assert Path.expand(target, Path.dirname(pack_ontology)) == Path.join(@root, "ontology.ttl")
    end

    test "generated sources declare themselves generated" do
      for generated <- Path.wildcard(Path.join(@root, "lib/ash_pplan/generated/*.ex")) do
        assert File.read!(generated) =~ "GENERATED by ggen_igniter from ontology.ttl."
      end
    end
  end

  defmodule PassThrough do
    use Reactor.Step

    @impl true
    def run(_arguments, context, _options), do: {:ok, context.ash_pplan.step_iri}
  end
end
