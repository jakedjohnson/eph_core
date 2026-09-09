defmodule EphCore.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jakedjohnson/eph_core"

  def project do
    [
      app: :eph_core,
      version: @version,
      elixir: "~> 1.17",
      description: description(),
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {EphCore.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:astro_utils, "~> 0.1.0"},
      {:ecto, "~> 3.12"},
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    []
  end

  defp description do
    "Pure Elixir ephemeris computation: time scales, JPL kernel evaluation, earth orientation, and sky snapshots from an observer location."
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE", "CHANGELOG.md", "CONTRIBUTING.md"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  # `dev/` is compiled in :dev, where docs are built, but is not shipped in the
  # Hex package, so sanity-check tasks stay out of the published docs.
  def documented_module?(module, _metadata) do
    not String.ends_with?(inspect(module), "SanityCheck")
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE"],
      groups_for_modules: [
        Core: [
          EphCore,
          EphCore.SnapshotPipeline,
          EphCore.SnapshotPipeline.Intent,
          EphCore.SnapshotPipeline.Observation
        ],
        "Pipeline stages": [
          EphCore.SnapshotPipeline.AstronomicalTime,
          EphCore.SnapshotPipeline.EarthOrientation,
          EphCore.SnapshotPipeline.Motion,
          EphCore.SnapshotPipeline.ObserverLineOfSight,
          EphCore.SnapshotPipeline.ObserverPosition,
          EphCore.SnapshotPipeline.SkyPosition,
          EphCore.SnapshotPipeline.SolarSystemPosition
        ],
        "Events and time series": [
          EphCore.Events.Almanac,
          EphCore.TimeSeries,
          EphCore.TopocentricMotion
        ],
        Corrections: [EphCore.Corrections.ApparentPlace],
        Stars: [EphCore.Stars.Catalog, EphCore.Stars.Position],
        "Time scales": ~r/^EphCore\.AstronomicalTime\./,
        "Earth orientation": ~r/^EphCore\.EarthOrientation\./,
        "Ephemeris and kernels": [EphCore.Ephemeris, ~r/^EphCore\.Ephemeris\./],
        Geometry: ~r/^EphCore\.Geometry\./
      ],
      filter_modules: &__MODULE__.documented_module?/2,
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
