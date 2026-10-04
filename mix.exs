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
      files:
        ~w(lib priv bin ontology.ttl ontology planning docs ecosystem.lock.toml mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end
end
