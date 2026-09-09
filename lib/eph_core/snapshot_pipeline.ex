defmodule EphCore.SnapshotPipeline do
  @moduledoc """
  Main pipeline for computing celestial body positions from a given location and time.

  The pipeline processes in stages:
  1. Intent validation
  2. Astronomical time conversion (shared context)
  3. Earth orientation (shared context)
  4. Observer position (shared context)
  5. Per-body: solar system positions, line of sight, sky positions
  6. Per-body: motion (optional)
  7. Manifest packaging

  Per-body stages can run in parallel for improved performance when computing
  multiple targets.
  """

  alias EphCore.Ephemeris
  alias EphCore.SnapshotPipeline.AstronomicalTime
  alias EphCore.SnapshotPipeline.EarthOrientation
  alias EphCore.SnapshotPipeline.Intent
  alias EphCore.SnapshotPipeline.Motion
  alias EphCore.SnapshotPipeline.ObserverLineOfSight
  alias EphCore.SnapshotPipeline.ObserverPosition
  alias EphCore.SnapshotPipeline.Snapshot
  alias EphCore.SnapshotPipeline.SkyPosition
  alias EphCore.SnapshotPipeline.SolarSystemPosition
  alias EphCore.SnapshotPipeline.Manifest

  # Parallelization is beneficial when we have enough bodies to offset Task overhead
  @parallel_threshold 3

  @doc """
  Compute sky positions for celestial bodies from a given location and time.

  Returns `{:ok, %EphCore.SnapshotPipeline.Observation{}}`, or
  `{:error, %Ecto.Changeset{}}` if the request fails validation in
  `EphCore.SnapshotPipeline.Intent`.

  ## Options

  Each option below is a map; omitted sub-keys keep their defaults.

  - `:models` — `:delta_t` (`:iers` | `:approximate`), `:earth_orientation`
    (`:gmst` | `:gast`), `:earth` (`:wgs84`), `:ecliptic_frame`
    (`:true_of_date` | `:mean_of_date` | `:j2000`).
  - `:corrections` — `:light_time` and `:aberration` (both `false` by default).
    Setting both enables the apparent-geocentric path, which adds
    `apparent_geocentric_*` fields to each body. `:precession_nutation` is a
    legacy flag; nutation is always applied for date-based ecliptic frames.
  - `:motion` — `:enabled` (default `true`) and `:dt_minutes` (default `30`),
    the half-window for the central-difference longitude rate.
  - `:geometry` — `:ring_samples` (default `24`, `0` to skip) for the
    celestial-sphere ring arcs.
  - `:parallel` — force per-body parallelism on or off. Defaults to `true` when
    at least #{@parallel_threshold} bodies are requested.

  ## Examples

      # Topocentric geometric (default)
      {:ok, observation} = observe(datetime, location, [:sun, :moon])

      # Apparent geocentric, matching published almanac positions
      {:ok, observation} =
        observe(datetime, location, [:neptune],
          corrections: %{aberration: true, light_time: true}
        )

  """
  def observe(datetime, location, bodies, opts \\ []) do
    intent_params =
      [utc: datetime, observer: location, targets: bodies]
      |> maybe_add_corrections(opts)
      |> maybe_add_models(opts)
      |> maybe_add_motion(opts)
      |> maybe_add_geometry(opts)

    parallel? = should_parallelize?(bodies, opts)

    with {:ok, snapshot} <- Intent.new(intent_params) do
      {:ok,
       snapshot
       |> AstronomicalTime.resolve()
       |> EarthOrientation.resolve()
       |> ObserverPosition.resolve()
       |> resolve_solar_system_positions(parallel?)
       |> Motion.resolve(parallel?)
       |> resolve_sky_positions(parallel?)
       |> Manifest.finalize()}
    end
  end

  defp should_parallelize?(bodies, opts) do
    case Keyword.get(opts, :parallel) do
      nil -> length(bodies) >= @parallel_threshold
      bool -> bool
    end
  end

  defp maybe_add_corrections(params, opts) do
    case Keyword.get(opts, :corrections) do
      nil -> params
      corrections -> Keyword.put(params, :corrections, corrections)
    end
  end

  defp maybe_add_models(params, opts) do
    case Keyword.get(opts, :models) do
      nil -> params
      models -> Keyword.put(params, :models, models)
    end
  end

  defp maybe_add_motion(params, opts) do
    case Keyword.get(opts, :motion) do
      nil -> params
      motion -> Keyword.put(params, :motion, motion)
    end
  end

  defp maybe_add_geometry(params, opts) do
    case Keyword.get(opts, :geometry) do
      nil -> params
      geometry -> Keyword.put(params, :geometry, geometry)
    end
  end

  # --- Solar System Positions (parallel or sequential) ---

  defp resolve_solar_system_positions(snapshot, true = _parallel?) do
    resolve_solar_system_positions_parallel(snapshot)
  end

  defp resolve_solar_system_positions(snapshot, false = _parallel?) do
    resolve_solar_system_positions_sequential(snapshot)
  end

  defp resolve_solar_system_positions_sequential(
         %Snapshot{
           intent: %{targets: targets},
           astronomical_time: %{jd_tt: jd_tt}
         } = snapshot
       ) do
    {:ok, cache} = Ephemeris.precompute_earth_ssb(jd_tt)

    positions =
      targets
      |> Enum.map(fn target ->
        {target, SolarSystemPosition.resolve_from_cache(snapshot, target, cache)}
      end)
      |> Map.new()

    %{snapshot | solar_system_positions: positions}
  end

  defp resolve_solar_system_positions_parallel(
         %Snapshot{
           intent: %{targets: targets},
           astronomical_time: %{jd_tt: jd_tt}
         } = snapshot
       ) do
    {:ok, cache} = Ephemeris.precompute_earth_ssb(jd_tt)

    positions =
      targets
      |> Task.async_stream(
        fn target ->
          {target, SolarSystemPosition.resolve_from_cache(snapshot, target, cache)}
        end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)
      |> Map.new()

    %{snapshot | solar_system_positions: positions}
  end

  # --- Sky Positions (parallel or sequential) ---

  defp resolve_sky_positions(snapshot, true = _parallel?) do
    resolve_sky_positions_parallel(snapshot)
  end

  defp resolve_sky_positions(snapshot, false = _parallel?) do
    resolve_sky_positions_sequential(snapshot)
  end

  defp resolve_sky_positions_sequential(
         %Snapshot{
           intent: %{targets: targets},
           solar_system_positions: positions
         } = snapshot
       ) do
    sky_positions =
      targets
      |> Enum.map(fn target ->
        solar_system_position = Map.fetch!(positions, target)
        line_of_sight = ObserverLineOfSight.resolve(snapshot, solar_system_position)
        sky_position = SkyPosition.resolve(snapshot, line_of_sight, solar_system_position)
        {target, sky_position}
      end)
      |> Map.new()

    %{snapshot | sky_positions: sky_positions}
  end

  defp resolve_sky_positions_parallel(
         %Snapshot{
           intent: %{targets: targets},
           solar_system_positions: positions
         } = snapshot
       ) do
    sky_positions =
      targets
      |> Task.async_stream(
        fn target ->
          solar_system_position = Map.fetch!(positions, target)
          line_of_sight = ObserverLineOfSight.resolve(snapshot, solar_system_position)
          sky_position = SkyPosition.resolve(snapshot, line_of_sight, solar_system_position)
          {target, sky_position}
        end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)
      |> Map.new()

    %{snapshot | sky_positions: sky_positions}
  end
end
