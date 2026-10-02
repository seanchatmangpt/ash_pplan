defmodule AshPPlan.MixProject do
  use Mix.Project

  @version "26.10.2"
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
      # ex4pm from Hex; ash_ex4pm (not on Hex) as a pinned git ref. The pinned ash_ex4pm still declares ex4pm 26.9.9, hence override: true until the user pushes a newer ash_ex4pm.
      {:ex4pm, "== 26.9.30", only: [:dev, :test], override: true},
      {:ash_ex4pm,
       github: "seanchatmangpt/ash_ex4pm",
       ref: "735ab7c326fdc2e5668ad4f21c598378d449d448",
       only: [:dev, :test]},
      # Ash policies need a SAT solver; only the test suite authorizes policies.
      {:simple_sat, "~> 0.1", only: :test},
      # ggen_igniter from Hex. The to:-substitution fix (per-row path rendering) lives
      # in the 26.9.31-class; the previous pin was a git ref to v26.9.31 (identical tree
      # to hex 26.9.31), so the hex pin admits it and anything newer with the fix.
      {:ggen_igniter, ">= 26.9.31", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [check: ["format --check-formatted", "test"]]
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
