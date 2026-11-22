defmodule Periodical.MixProject do
  @moduledoc false
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/joetjen/periodical"

  @spec project() :: keyword()
  def project do
    [
      app: :periodical,
      version: @version,
      elixir: "~> 1.19",
      name: "Periodical",
      description: "Bounded local recurring and one-time scheduler for supervised Elixir callbacks",
      source_url: @source_url,
      homepage_url: "https://joetjen.github.io/periodical",
      docs: docs(),
      dialyzer: dialyzer(),
      aliases: aliases(),
      package: package(),
      test_paths: ["test/periodical"],
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # Test support is compiled to disk so the peer nodes of the multi-instance
  # tests can load it from the code path.
  @spec elixirc_paths(atom()) :: [Path.t()]
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  @spec application() :: keyword()
  def application, do: [mod: {Periodical.Application, []}, extra_applications: [:crypto, :logger, :runtime_tools]]

  @spec cli() :: keyword()
  def cli do
    [preferred_envs: [credo: :dev, dialyzer: :dev, docs: :docs, "hex.publish": :docs, precommit: :dev, test: :test]]
  end

  @spec dialyzer() :: keyword()
  def dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_core_path: "_build/plts",
      plt_file: {:no_warn, "_build/plts/dialyzer.plt"}
    ]
  end

  @spec docs() :: keyword()
  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      homepage_url: "https://joetjen.github.io/periodical",
      extras: [
        "README.md",
        "guides/usage.md",
        "guides/examples.md",
        "guides/architecture.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_extras: [Guides: ~r|^guides/|],
      # The changelog's history names functions and modules that no longer
      # exist or are internal.
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      groups_for_modules: [
        Core: [Periodical, Periodical.Schedule, Periodical.Trigger],
        Coordination: [Periodical.Coordinator, Periodical.Coordinator.Claim],
        Support: [Periodical.Config, Periodical.Error, Periodical.Stats, Periodical.Telemetry]
      ]
    ]
  end

  @spec package() :: keyword()
  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url, "Docs" => "https://joetjen.github.io/periodical"},
      files: ~w(lib guides .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  @spec aliases() :: keyword()
  defp aliases do
    [
      build: ["compile --force --warnings-as-errors"],
      precommit: [
        "build",
        "format --check-formatted",
        "credo --strict",
        "dialyzer",
        "cmd sh -c 'MIX_ENV=test mix test'"
      ]
    ]
  end

  @spec deps() :: [Mix.Project.dependency()]
  defp deps do
    [
      # development and test dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: [:docs], runtime: false},
      {:stream_data, "~> 1.2", only: [:dev, :test]},

      # runtime dependencies
      {:ephemeris, "~> 0.1"},
      {:telemetry, "~> 1.3"}
    ]
  end
end
