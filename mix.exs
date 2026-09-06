defmodule AshPPlan.MixProject do
  use Mix.Project

  @version "26.9.6"
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
      description: "P-PLAN/PROV-O semantic projection into Ash.Reactor, AshOban and scheduling",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:ash, "~> 3.33"},
      {:reactor, "~> 1.0"},
      {:ash_oban, "~> 0.8"},
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
      files: ~w(lib priv ontology.ttl ontology planning docs mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end
end
