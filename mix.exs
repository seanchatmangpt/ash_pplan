defmodule AshPPlan.MixProject do
  use Mix.Project

  @version "26.10.3"
  @source_url "https://github.com/seanchatmangpt/ash_pplan"

  def project do
    [
      app: :ash_pplan,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      # test/petal_framework/ is an untracked demo clone; its generator
      # templates and vendored dep tests (EEx *_test.exs sources) are not
      # runnable tests. Load filters take precedence over ignore filters, so
      # the load filter itself must exclude the subtree (an ignore filter
      # alone is insufficient — proven: the EEx files still compiled).
      # These filters require Elixir >= 1.19 (test_load_filters is a 1.19
      # feature). On the 1.17 floor there is NO filter mechanism, so the 19
      # vendored Phoenix generator templates matching *_test.exs under
      # test/petal_framework/demo_graph/deps/*/priv/templates/ were renamed
      # to *_test.exs.eex (they are EEx templates; gitignored clone, not
      # upstream bytes in this repo). Renaming, not config, is the durable
      # cross-toolchain fix.
      test_load_filters: [
        fn path ->
          String.ends_with?(path, "_test.exs") and
            not String.contains?(path, "test/petal_framework/")
        end
      ],
      test_ignore_filters: [
        # Everything else under the demo clone (.ex/.exs generator templates,
        # vendored dep tests, config) — silences the loader's
        # unmatched-candidate warning for the non-`_test.exs` files.
        ~r{^test/petal_framework/},
        # fixture .exs files that are not *_test.exs.
        ~r{^test/durable/lane_b_fixture\.exs$},
        ~r{^test/standing/standing_fixtures\.exs$}
      ],
      deps: deps(),
      aliases: aliases(),
      package: package(),
      description: "P-PLAN/PROV-O control plane over Ash, AshStateMachine, Reactor and AshOban",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  # The check alias runs mix test, so it must declare its own CLI environment.
  # Without this the alias refuses in :dev and the release gate's central step
  # exits without running a single test.
  def cli do
    [preferred_envs: [check: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.33 and >= 3.33.11"},
      {:reactor, "~> 1.0"},
      {:reactor_req, "~> 0.1"},
      {:reactor_file, "~> 0.18"},
      {:bb_reactor, "~> 0.2", only: [:dev, :test]},
      {:bandit, "~> 1.5", only: [:dev, :test]},
      {:plug, "~> 1.16", only: [:dev, :test]},
      {:opentelemetry_api, "~> 1.4", optional: true},
      # vendored: upstream 0.5.0 pins `reactor == 1.0.6`; relaxed to `~> 1.0` (see vendor/README.md)
      {:reactor_process, path: "vendor/reactor_process", only: [:dev, :test]},
      {:ash_state_machine, "~> 0.2.13"},
      {:ash_oban, "~> 0.9"},
      # AshPPlan.Compiler applies Reactor's own behaviour check when admitting a
      # step implementation, so spark is a direct call, not a transitive.
      {:spark, "~> 2.7"},
      # ex4pm and ash_ex4pm both from Hex since ash_ex4pm 26.10.0; the
      # former override is gone because ash_ex4pm ~> 26.10 declares a
      # compatible ex4pm requirement.
      {:ex4pm, "~> 26.10", only: [:dev, :test]},
      {:ash_ex4pm, ">= 26.10.0", only: [:dev, :test]},
      # Ash policies need a SAT solver; only the test suite authorizes policies.
      {:simple_sat, "~> 0.1", only: :test},
      # ggen_igniter from Hex. The to:-substitution fix (per-row path rendering) lives
      # in the 26.9.31-class; the previous pin was a git ref to v26.9.31 (identical tree
      # to hex 26.9.31), so the hex pin admits it and anything newer with the fix.
      {:ggen_igniter, ">= 26.9.31", only: [:dev, :test], runtime: false},
      # Marketplace-sim LiveView court (test/marketplace_sim/web/): Phoenix
      # LiveView rendered through Phoenix.LiveViewTest. These are already
      # transitive (ash_admin/ash_phoenix pull phoenix_live_view ~> 1.0), so
      # the constraints are declared test-only and lock-stable. bandit (above)
      # serves the test endpoint's adapter.
      {:phoenix, "~> 1.7", only: [:dev, :test]},
      # Petal UI kit: ash_pplan imports only PetalComponents.* (badges/cards/
      # tables) — published on Hex; badges/cards render the marketplace-sim
      # explorer and the fleet dashboard. The test/petal_framework clone stays
      # on disk as the NetworkGraph hook's dev home but is no longer a dep.
      {:petal_components, "~> 2.8", only: [:dev, :test]},
      # Phoenix.LiveViewTest element/DOM helpers need an HTML parser.
      {:lazy_html, "~> 0.1", only: [:dev, :test]},
      # petal_components pins gettext ~> 0.26 while cinder (via ash_admin) pins
      # ~> 1.0 — override to the lock's 1.x; petal_components uses the stable
      # dgettext surface, which 1.x keeps.
      {:gettext, "~> 1.0", override: true, only: [:dev, :test]},
      # petal_components pins websock_adapter ~> 0.5.7 while phoenix (via bandit)
      # is on 0.6 — override to the lock's 0.6 line; the adapter API surface
      # petal_components touches is stable across 0.5/0.6.
      {:websock_adapter, "~> 0.6", override: true, only: [:dev, :test]},
      {:phoenix_live_view, "~> 1.0", only: [:dev, :test]},
      # jason is already a prod requirement of ash — a scoped entry is rejected
      # by the resolver, so it is declared unscoped to keep the court explicit.
      {:jason, "~> 1.4"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      check: ["format --check-formatted", "test"],
      # Spark extension toolchain (docs + formatter), matching ash_state_machine:
      # both first-party extensions register through the same spark.* tasks.
      "spark.formatter": "spark.formatter --extensions AshPPlan.Dsl.PPlan,AshPPlan.Workflow.Dsl",
      "spark.cheat_sheets":
        "spark.cheat_sheets --extensions AshPPlan.Dsl.PPlan,AshPPlan.Workflow.Dsl",
      "spark.cheat_sheets_in_search":
        "spark.cheat_sheets_in_search --extensions AshPPlan.Dsl.PPlan,AshPPlan.Workflow.Dsl",
      "spark.replace_doc_links": "spark.replace_doc_links"
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # lib/mix/tasks/ash_pplan.gen.workflow.ex `use Igniter.Mix.Task`; igniter is
      # a dev/test-only dep, so shipping the task in the hex package would make it
      # uncompilable for consumers. `lib/mix` is stripped here; the task stays
      # functional in-repo.
      files: package_files()
    ]
  end

  # `lib/mix` is stripped from the hex package: lib/mix/tasks/ash_pplan.gen.workflow.ex
  # does `use Igniter.Mix.Task` and igniter is a dev/test-only dep, so shipping the
  # task would make the package uncompilable for consumers. The task stays functional
  # in-repo. Hex has no `exclude` for `files:`, so the subtraction is done here.
  defp package_files do
    base =
      ~w(config lib priv bin ontology.ttl ontology planning docs ecosystem.lock.toml mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)

    base
    |> Enum.flat_map(fn
      "lib" ->
        # NOTE: the bare "lib" directory entry must NOT be included — hex copies
        # directory entries recursively, which would drag lib/mix back in.
        Path.wildcard("lib/**")
        |> Enum.reject(&(&1 == "lib/mix" or String.starts_with?(&1, "lib/mix/")))

      other ->
        [other]
    end)
    |> Enum.uniq()
  end
end
