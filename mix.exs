defmodule Staxx.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      aliases: aliases()
    ]
  end

  defp releases() do
    [
      staxx: [
        include_executables_for: [:unix],
        applications: [
          runtime_tools: :permanent,
          instance: :permanent,
          docker: :permanent,
          event_stream: :permanent,
          json_rpc: :permanent,
          metrix: :permanent,
          store: :permanent,
          # snapshot_registry: :permanent,
          testchain: :permanent,
          utils: :permanent,
          web_api: :permanent
        ]
      ]
    ]
  end

  defp aliases do
    [
      drop_db: [
        "ecto.drop --quiet"
      ],
      setup_db: [
        "ecto.create --quiet",
        "ecto.migrate",
        "run #{__DIR__}/apps/store/priv/repo/seeds.exs"
      ],
      test: ["drop_db", "setup_db", "test"],
      reset: ["deps.get", "drop_db", "setup_db"]
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    [
      {:telemetry, "~> 0.4"},
      {:credo, "~> 1.1.0", only: [:dev, :test], runtime: false}
    ]
  end
end
