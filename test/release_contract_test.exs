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

    test "a role can be looked up by string as well as by atom" do
      assert AshPPlan.projections_for("temporal") == AshPPlan.projections_for(:temporal)
      assert AshPPlan.projections_for("release-evidence") != []
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

    test "persistence is owned by the durable ledger Store behaviour, not a consumer gap" do
      assert [%{status: "reuse", owner: "durable", target: "AshPPlan.Reactor.Durable"}] =
               AshPPlan.projections_for(:persistence)
    end

    test "ash_pplan only owns the projections it declares as extensions" do
      owned = Enum.filter(AshPPlan.projections(), &(&1.owner == "ash_pplan"))

      assert owned != []
      assert Enum.all?(owned, &(&1.status == "extension"))

      # Semantic execution, its evidence, and release observation are the
      # extensions this release claims; everything else stays owned by an
      # existing runtime.
      assert owned |> Enum.map(& &1.role) |> Enum.sort() ==
               ["evidence", "execution", "observation", "release-evidence"]
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
            "mix hex.audit",
            "./bin/conform",
            "./bin/conform-falsify",
            "mix check",
            "./bin/manufacture",
            "./bin/verify-package",
            "./bin/receipt"
          ] do
        assert ci =~ gate, "CI does not run the release gate step: #{gate}"
      end

      # The generated-diff gate must cover every manufacture output surface.
      # CI may cover a superset (e.g. `test/courts` wholesale or `priv/tla`),
      # so each ManufactureTargets dir needs a token that contains it.
      diff_line =
        ci
        |> String.split("\n")
        |> Enum.find(&String.contains?(&1, "git diff --exit-code"))

      assert diff_line, "CI does not run the generated-diff gate"

      diff_tokens = String.split(diff_line)

      for dir <- AshPPlan.ManufactureTargets.generated_dirs() do
        covered? =
          Enum.any?(
            diff_tokens,
            &(&1 == dir or String.starts_with?(dir, &1 <> "/"))
          )

        assert covered?,
               "the CI generated-diff gate does not cover the manufacture target: #{dir}"
      end
    end

    test "the manufacturer reference in mix.exs matches the producer lock" do
      lock = @root |> Path.join("ecosystem.lock.toml") |> File.read!()
      mix = @root |> Path.join("mix.exs") |> File.read!()

      # Since the hex-pin switch (26.10.2), mix.exs consumes ggen_igniter from
      # Hex with a version floor; the lock records the same floor and the sha
      # of the audited git tree the floor admits.
      [_, locked_floor] =
        Regex.run(~r/^\[ggen_igniter\]\n(?:.*\n)*?transport = "hex, floor >= ([0-9.]+)"/m, lock)

      assert mix =~ ~s({:ggen_igniter, ">= #{locked_floor}"),
             "mix.exs consumes a different ggen_igniter floor than ecosystem.lock.toml records"

      [_, locked_sha] = Regex.run(~r/^\[ggen_igniter\]\n(?:.*\n)*?sha = "([0-9a-f]{40})"/m, lock)

      assert mix =~ locked_sha or
               File.read!(Path.join(@root, "receipts/hex-pin-26.10.2.md")) =~ locked_sha,
             "the lock's audited ggen_igniter tree sha must stay recorded somewhere auditable"
    end

    test "the resolved dependency tree matches the versions the lock claims to have observed" do
      lock = @root |> Path.join("mix.lock") |> File.read!()
      ecosystem = @root |> Path.join("ecosystem.lock.toml") |> File.read!()

      for dependency <- ~w(ash reactor ash_state_machine ash_oban) do
        [_, observed] =
          Regex.run(~r/^\[#{dependency}\]\nversion_observed = "([^"]+)"/m, ecosystem)

        assert lock =~ ~s("#{dependency}": {:hex, :#{dependency}, "#{observed}"),
               "ecosystem.lock.toml observes #{dependency} #{observed}, mix.lock resolves something else"
      end
    end

    test "the lock covers the dev/test dependency changes and matches mix.lock and mix.exs" do
      ecosystem = @root |> Path.join("ecosystem.lock.toml") |> File.read!()
      lock = @root |> Path.join("mix.lock") |> File.read!()
      mix = @root |> Path.join("mix.exs") |> File.read!()

      for dependency <- ~w(bb_reactor bandit plug stream_data ex4pm opentelemetry_api) do
        [_, observed] = Regex.run(~r/^#{dependency} = "([^"]+)"/m, ecosystem)

        assert lock =~ ~s("#{dependency}": {:hex, :#{dependency}, "#{observed}"),
               "ecosystem.lock.toml records #{dependency} #{observed}, mix.lock resolves something else"
      end

      # Since the hex-pin switch (26.10.2), ash_ex4pm is consumed from Hex
      # with a version floor; no git ref, no override.
      [_, ash_ex4pm_floor] =
        Regex.run(~r/^ash_ex4pm_floor = "([0-9.]+)"/m, ecosystem)

      assert mix =~ ~s({:ash_ex4pm, ">= #{ash_ex4pm_floor}"),
             "mix.exs consumes a different ash_ex4pm floor than ecosystem.lock.toml records"

      assert lock =~ ~s("ash_ex4pm": {:hex, :ash_ex4pm,)

      # gettext and websock_adapter carry the only permitted overrides: both are
      # required by the vendored petal_framework and are pinned to the lock's
      # existing versions (see the mix.exs dep comments). Any override beyond
      # these two is a contract violation.
      override_lines =
        mix |> String.split("\n") |> Enum.filter(&String.contains?(&1, "override: true"))

      assert length(override_lines) == 2,
             "mix.exs declares #{length(override_lines)} overrides; exactly the two documented petal_framework overrides are permitted"

      for line <- override_lines do
        assert line =~ ~r/\{:gettext, "\~> 1\.0", override: true/ or
                 line =~ ~r/\{:websock_adapter, "\~> 0\.6", override: true/,
               "unexpected override in mix.exs: #{line}"
      end

      # Since the petal dep-strategy switch (ECO-PETAL-DEP-STRATEGY), the Petal
      # UI kit is consumed from Hex as petal_components; the test/petal_framework
      # clone on disk is the NetworkGraph hook's dev home only — undepended.
      assert mix =~ ~s({:petal_components, "~> 2.8", only: [:dev, :test]})
      refute mix =~ "petal_framework, path:"
      refute mix =~ ~s(path: "test/petal_framework")

      # Path dependencies are dev/test only: the vendored reactor_process is
      # the sole remaining path dep.
      assert mix =~ ~s({:reactor_process, path: "vendor/reactor_process", only: [:dev, :test]})
      assert mix |> String.split("path:") |> length() == 2

      # stream_data arrives through ash, so mix.exs must not declare it.
      refute mix =~ ":stream_data"
    end

    test "lock standing is truthfully stated with a stale_reason for every unobserved claim" do
      ecosystem = @root |> Path.join("ecosystem.lock.toml") |> File.read!()

      for section <- ~w(ggen_ecosystem durable_engine dev_test_dependencies) do
        [_, body] = Regex.run(~r/^\[#{section}\]\n((?:.+\n)*)/m, ecosystem)
        # The lock must state a standing (UNKNOWN *or* OBSERVED via a direct registry/API
        # observation receipt) and must carry a stale_reason for every claim not yet
        # witnessed by an exact-head CI run.
        assert body =~ ~r/standing = "(UNKNOWN|OBSERVED)"/,
               "#{section} standing is not a truthful value"

        assert body =~ ~r/stale_reason = ".+"/, "#{section} lacks a stale_reason"
      end
    end

    test "the declared ash requirement excludes versions below the advisory floor" do
      ecosystem = @root |> Path.join("ecosystem.lock.toml") |> File.read!()
      [_, floor] = Regex.run(~r/^\[ash\]\n(?:.*\n)*?version_floor = "([^"]+)"/m, ecosystem)

      {_, requirement} =
        Enum.find(
          Mix.Project.config()[:deps],
          &match?({:ash, requirement} when is_binary(requirement), &1)
        )

      requirement = Version.parse_requirement!(requirement)
      [major, minor, patch] = floor |> String.split(".") |> Enum.map(&String.to_integer/1)
      below_floor = Version.parse!("#{major}.#{minor}.#{patch - 1}")

      assert Version.match?(Version.parse!(floor), requirement)

      refute Version.match?(below_floor, requirement),
             "mix.exs admits ash #{below_floor}, below the advisory floor #{floor}"
    end

    test "the manufacture and conformance entrypoints are executable" do
      for script <-
            ~w(bin/manufacture bin/conform bin/conform-falsify bin/receipt bin/verify-package bin/gate bin/observe-ontology) do
        path = Path.join(@root, script)

        assert File.exists?(path), "#{script} is missing"
        assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
        assert Bitwise.band(mode, 0o111) != 0, "#{script} is not executable"
      end
    end
  end

  describe "CI hardening" do
    setup do
      %{
        ci: @root |> Path.join(".github/workflows/ci.yml") |> File.read!(),
        mix: @root |> Path.join("mix.exs") |> File.read!()
      }
    end

    test "every third-party action is pinned to a full commit SHA", %{ci: ci} do
      uses = Regex.scan(~r/^\s*-?\s*uses:\s*(\S+)/m, ci)
      assert uses != []

      for [_, spec] <- uses do
        assert spec =~ ~r/^[\w.-]+\/[\w.-]+@[0-9a-f]{40}$/,
               "#{spec} is not pinned to a 40-hex commit SHA; a moved tag could change what CI runs"
      end
    end

    test "every job is time-bounded", %{ci: ci} do
      jobs =
        ci
        |> String.split(~r/^jobs:\n/m)
        |> List.last()
        |> then(&Regex.scan(~r/^  [\w-]+:\n/m, &1))

      assert length(jobs) >= 4
      assert length(Regex.scan(~r/^    timeout-minutes: \d+$/m, ci)) == length(jobs)
    end

    test "CI never widens the default read-only token", %{ci: ci} do
      assert ci =~ ~r/^permissions:\n  contents: read$/m
      refute ci =~ ~r/^\s+(contents|id-token|packages|pull-requests): write/m
    end

    test "a single aggregate job joins every gate and refuses on any non-success", %{ci: ci} do
      assert ci =~ "release-gate:"
      assert ci =~ "needs: [semantic, conformance, elixir]"
      # Without `always()` a failed dependency would skip the aggregate, and a
      # skipped required check reads as passing in branch protection.
      assert ci =~ ~r/release-gate:\n\s+name: release-gate\n\s+if: \$\{\{ always\(\) \}\}/
    end

    test "the Elixir version declared in mix.exs is tested at its floor", %{ci: ci, mix: mix} do
      [_, floor] = Regex.run(~r/elixir: "~> (\d+\.\d+)"/, mix)

      assert ci =~ ~r/elixir: '#{Regex.escape(floor)}\.\d+'/,
             "CI does not run the Elixir floor #{floor} that mix.exs declares"
    end

    test "CI refuses a stale or unused lock and audits dependencies", %{ci: ci} do
      assert ci =~ "mix deps.get --check-locked"
      assert ci =~ "mix deps.unlock --check-unused"
      assert ci =~ "mix hex.audit"
    end

    test "advisories are also swept on a schedule, not only on pull requests", %{ci: ci} do
      assert ci =~ ~r/^  schedule:\n    - cron: /m
    end

    test "Dependabot covers both dependency ecosystems the CI consumes" do
      dependabot = @root |> Path.join(".github/dependabot.yml") |> File.read!()

      assert dependabot =~ "package-ecosystem: mix"
      assert dependabot =~ "package-ecosystem: github-actions"
    end

    test "the ontology parse runs a reviewed script, not inline YAML python", %{ci: ci} do
      assert ci =~ "bin/observe-ontology"
      refute ci =~ "python3 -c"
    end
  end

  describe "semantic authority" do
    test "pack ontologies are real files stamped with provenance, matching the root source" do
      for pack_dir <- ["ash-pplan-pack", "ash-pplan-workflow-pack"] do
        pack_ontology = Path.join([@root, "priv/ggen", pack_dir, "ontology.ttl"])

        # The pack-digest court (ggen_igniter >= 26.10.1) refuses symlinks that
        # escape the pack root, so the copy convention is a real file + header.
        assert {:error, _} = File.read_link(pack_ontology)
        content = File.read!(pack_ontology)

        assert content =~
                 "GENERATED-PROVENANCE: real-file copy of the canonical repo-root ontology.ttl"

        header_lines = 4
        body = content |> String.split("\n") |> Enum.drop(header_lines) |> Enum.join("\n")

        assert body == File.read!(Path.join(@root, "ontology.ttl"))
      end
    end

    test "generated sources declare themselves generated" do
      for %{out: out} <- AshPPlan.ManufactureTargets.targets() do
        path = Path.join(@root, out)

        assert File.exists?(path),
               "manufacture target #{out} does not exist on disk"

        assert File.read!(path) =~ "GENERATED by ggen_igniter",
               "manufacture target #{out} does not carry the ggen_igniter generated marker"
      end
    end
  end

  defmodule PassThrough do
    use Reactor.Step

    @impl true
    def run(_arguments, context, _options), do: {:ok, context.ash_pplan.step_iri}
  end
end
