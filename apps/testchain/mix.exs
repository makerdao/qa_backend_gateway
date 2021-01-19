defmodule Staxx.Testchain.MixProject do
  use Mix.Project

  def project do
    [
      app: :testchain,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.9",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      included_applications: [:ksha3]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Staxx.Testchain.Application, []}
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["test/support" | elixirc_paths()]
  defp elixirc_paths(_), do: elixirc_paths()
  defp elixirc_paths, do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:json_rpc, in_umbrella: true},
      {:docker, in_umbrella: true},
      {:event_stream, in_umbrella: true},
      {:store, in_umbrella: true},
      {:utils, in_umbrella: true},
      {:poison, "~> 3.1"},
      {:poolboy, "~> 1.5.1"},
      {:ksha3, "~> 1.0.0", git: "https://github.com/onyxrev/ksha3.git", branch: "master"},
      {:ethereum_wallet, github: "onyxrev/ethereum_wallet_elixir"},
      {:jason, "~> 1.1"},
      {:faker, "~> 0.11", only: :test},
      {:progress_bar, "~> 2.0", only: [:dev, :test]}
    ]
  end
end
