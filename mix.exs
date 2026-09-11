defmodule AshPPlan.MixProject do
  use Mix.Project

  @version "26.9.7"
  @source_url "https://github.com/seanchatmangpt/ash_pplan"
  @ggen_igniter_ref "39ba9e128653d5f56d44e9c68a0339d62e3e1beb"

  def project do
    [
      app: :ash_pplan,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
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

  defp deps do
    [
      {:ash, "~> 3.33"},
      {:reactor, "~> 1.0"},
      {:ash_state_machine, "~> 0.2.13"},
      {:ash_oban, "~> 0.8"},
      # AshPPlan.Compiler applies Reactor's own behaviour check when admitting a
      # step implementation, so spark is a direct call, not a transitive.
      {:spark, "~> 2.7"},
      {:ggen_igniter,
       git: "https://github.com/seanchatmangpt/ggen_igniter.git",
       ref: @ggen_igniter_ref,
       only: [:dev, :test],
       runtime: false}
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
