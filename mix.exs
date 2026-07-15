defmodule ObanQuackDB.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/elixir-vibe/oban_quackdb"

  def project do
    [
      app: :oban_quackdb,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:ex_unit]],
      name: "Oban QuackDB",
      description: "An experimental QuackDB engine for Oban",
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      oban_dep(),
      {:quackdb, "~> 0.5.17"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.6", only: [:dev, :test], runtime: false},
      {:vibe_kit, "~> 0.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp oban_dep do
    case System.get_env("OBAN_QUACKDB_OBAN_PATH") do
      path when path in [nil, ""] -> {:oban, "~> 2.23.0"}
      path -> {:oban, path: Path.expand(path), override: true}
    end
  end

  defp aliases do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "docs --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end

  defp package do
    [
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE.txt),
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "QuackDB" => "https://github.com/elixir-vibe/quackdb"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "LICENSE.txt"]
    ]
  end
end
