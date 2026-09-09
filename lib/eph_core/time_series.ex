defmodule EphCore.TimeSeries do
  @moduledoc """
  Batch position computation for time-grid scanning.

  Bypasses the full SnapshotPipeline (no sky positions, no horizon geometry)
  but reproduces its observer line-of-sight when an `:observer` is supplied,
  so the grid and the refinement `position_fn` share a single coordinate frame.

  Computes ecliptic longitudes in the true-of-date ecliptic frame and equatorial
  declinations from the ICRF vector, optimized for scanning hundreds of timestamps.

  ## Frames

  - **Geocentric** (no observer): the body's geocentric ICRF vector is converted
    directly. Use this when parallax does not matter.
  - **Topocentric** (observer supplied): the observer's WGS84 position is rotated
    into the inertial (ICRF/J2000) frame via GMST — matching
    `EphCore.SnapshotPipeline.ObserverPosition` with `earth_orientation: :gmst`
    and `precession_nutation: false` — then subtracted from the geocentric vector
    before the ecliptic/declination conversion. This is the same geometry the
    refinement path produces (`SkyPosition.topocentric_ecliptic_longitude` with
    the default `ecliptic_frame: :true_of_date`), so grid minima and refined
    exacts agree to within scanning tolerance.

  Motion rates are derived via central difference on the longitude array —
  this reuses already-computed positions rather than making extra SPK calls.

  Call `add_horizon_geometry/2` after `compute/3` to attach MC/ASC, alt/az, LST,
  and obliquity columns for chart overlay workflows. Refinement calls can use the
  full `EphCore.SnapshotPipeline.observe/4` via a position_fn injection pattern.
  """

  alias EphCore.AstronomicalTime.{JulianDay, TerrestrialTime, UniversalTimeOne}
  alias EphCore.EarthOrientation.Sidereal
  alias EphCore.Ephemeris
  alias EphCore.Geometry.{Ecliptic, Geodetic, Horizon}
  alias AstroUtils.{Angle, Coordinates, Matrix3, Vector}

  @type observer :: %{optional(atom()) => float()}

  @type grid_data :: %{
          optional(:timestamps) => [DateTime.t()],
          optional(:positions) => %{atom() => [float()]},
          optional(:declinations) => %{atom() => [float()]},
          optional(:motion) => %{atom() => [float()]},
          optional(:axes) => %{mc: [float()], asc: [float()]},
          optional(:altitudes) => %{atom() => [float()]},
          optional(:azimuths) => %{atom() => [float()]},
          optional(:lst) => [float()],
          optional(:obliquity_deg) => [float()],
          optional(:observer_lat) => float()
        }

  @doc """
  Compute ecliptic longitudes, equatorial declinations, and motion rates for a
  batch of timestamps.

  ## Arguments
  - `timestamps` — list of UTC `DateTime` structs, assumed evenly spaced
  - `bodies` — list of body atoms (e.g. `[:venus, :sun, :moon]`)
  - `opts` — keyword list:
    - `:observer` — `%{lat: float, lon: float, height: float}` (WGS84). When
      present, longitudes and declinations are **topocentric**; when absent or
      `nil`, they are **geocentric**.

  ## Returns
  `{:ok, grid_data}` where grid_data has:
  - `timestamps` — the input list (unchanged)
  - `positions` — `%{body_atom => [lon_deg_t0, lon_deg_t1, ...]}` (true-of-date ecliptic)
  - `declinations` — `%{body_atom => [dec_deg_t0, dec_deg_t1, ...]}` (J2000 equatorial)
  - `motion` — `%{body_atom => [rate_deg_per_day_t0, ...]}`

  All arrays are parallel: index i corresponds to `timestamps[i]`.
  Motion rates are in degrees/day (positive = direct, negative = retrograde).
  """
  @spec compute([DateTime.t()], [atom()], keyword()) :: {:ok, grid_data()} | {:error, term()}
  def compute(timestamps, bodies, opts \\ []) when is_list(timestamps) and is_list(bodies) do
    observer_ecef = observer_ecef(Keyword.get(opts, :observer))
    time_pairs = Enum.map(timestamps, fn utc -> {utc, datetime_to_jd_tt(utc)} end)

    {lons_by_body, decs_by_body} = compute_positions(time_pairs, bodies, observer_ecef)
    interval_days = compute_interval_days(timestamps)
    rates_by_body = compute_motion_rates(lons_by_body, interval_days)

    {:ok,
     %{
       timestamps: timestamps,
       positions: lons_by_body,
       declinations: decs_by_body,
       motion: rates_by_body
     }}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Augment a position grid with observer horizon geometry for each timestamp.

  Adds MC/ASC ecliptic longitudes, LST, obliquity, and per-body altitude/azimuth
  columns derived from the grid's topocentric ecliptic longitudes. Intended for
  chart and event-search overlays built on top of a scanned grid.

  ## Arguments
  - `grid_data` — result of `compute/3` (must include `:timestamps` and `:positions`)
  - `observer` — `%{lat: float, lon: float, height: float}` (WGS84)

  ## Returns
  The input map extended with:
  - `:axes` — `%{mc: [float()], asc: [float()]}`
  - `:altitudes`, `:azimuths` — `%{body_atom => [float()]}`
  - `:lst`, `:obliquity_deg` — parallel arrays
  - `:observer_lat` — observer latitude in degrees
  """
  @spec add_horizon_geometry(grid_data(), observer()) :: grid_data()
  def add_horizon_geometry(%{timestamps: timestamps, positions: positions} = grid_data, observer)
      when is_list(timestamps) and is_map(positions) do
    {lat, lon} = observer_lat_lon(observer)

    horizon_rows =
      Enum.map(timestamps, fn dt ->
        jd_tt = datetime_to_jd_tt(dt)
        hor = Horizon.ecliptic_lon_at_east_horizon(jd_tt, lat, lon)
        mc = Horizon.ecliptic_lon_on_meridian(jd_tt, lon)
        {hor, mc.meridian_ecliptic_longitude}
      end)

    lsts = Enum.map(horizon_rows, fn {hor, _} -> hor.lst end)
    obliquities = Enum.map(horizon_rows, fn {hor, _} -> hor.obliquity end)
    asc_list = Enum.map(horizon_rows, fn {hor, _} -> hor.east_horizon_ecliptic_longitude end)
    mc_list = Enum.map(horizon_rows, fn {_, mc} -> mc end)

    grid_data
    |> Map.put(:axes, %{mc: mc_list, asc: asc_list})
    |> Map.put(:altitudes, sky_columns(positions, lsts, obliquities, lat, :altitude))
    |> Map.put(:azimuths, sky_columns(positions, lsts, obliquities, lat, :azimuth))
    |> Map.put(:lst, lsts)
    |> Map.put(:obliquity_deg, obliquities)
    |> Map.put(:observer_lat, lat)
  end

  # ---------------------------------------------------------------------------
  # JD_TT conversion
  # ---------------------------------------------------------------------------

  defp datetime_to_jd_tt(%DateTime{} = utc) do
    utc |> TerrestrialTime.from_utc() |> JulianDay.from_datetime()
  end

  # ---------------------------------------------------------------------------
  # Observer geometry (topocentric)
  # ---------------------------------------------------------------------------

  # WGS84 → ECEF (km). Constant across timestamps; rotated into ICRF per sample.
  defp observer_ecef(nil), do: nil

  defp observer_ecef(%{} = observer) do
    {lat, lon} = observer_lat_lon(observer)
    height = observer[:height] || observer[:elevation] || 0.0
    Geodetic.to_ecef_km(lat, lon, height)
  end

  defp observer_lat_lon(%{} = observer) do
    lat = observer[:lat] || observer[:latitude] || 0.0
    lon = observer[:lon] || observer[:longitude] || 0.0
    {lat, lon}
  end

  defp sky_columns(positions, lsts, obliquities, lat, component) do
    count = length(lsts)

    Map.new(positions, fn {body, lons} ->
      values =
        0..(count - 1)
        |> Enum.map(fn idx ->
          lon = Enum.at(lons, idx)
          lst = Enum.at(lsts, idx)
          obl = Enum.at(obliquities, idx)
          {alt, az} = Coordinates.ecliptic_to_horizontal(lon, obl, lst, lat)
          if component == :altitude, do: alt, else: az
        end)

      {body, values}
    end)
  end

  # Observer position in the inertial (ICRF) frame at a given epoch. Mirrors
  # SnapshotPipeline.ObserverPosition with model :gmst / precession_nutation false.
  defp observer_icrf(nil, _utc, _jd_tt), do: nil

  defp observer_icrf(ecef, utc, jd_tt) do
    jd_utc = JulianDay.from_datetime(utc)
    mjd_utc = JulianDay.modified_julian_day(jd_utc)
    ut1_utc = UniversalTimeOne.delta_for_mjd_utc(mjd_utc)
    jd_ut1 = UniversalTimeOne.apply_delta(jd_utc, ut1_utc)

    gmst_rad = Sidereal.gmst_iau_2006(jd_ut1, jd_tt) * :math.pi() / 180.0
    Matrix3.multiply_vector(Matrix3.rot_z(gmst_rad), ecef)
  end

  defp line_of_sight(geocentric_km, nil), do: geocentric_km
  defp line_of_sight(geocentric_km, observer_km), do: Vector.subtract(geocentric_km, observer_km)

  # ---------------------------------------------------------------------------
  # Position computation (longitude + declination in one pass)
  # ---------------------------------------------------------------------------

  # Returns {%{body_atom => [lon_t0, ...]}, %{body_atom => [dec_t0, ...]}}
  defp compute_positions(time_pairs, bodies, observer_ecef) do
    per_timestamp =
      Enum.map(time_pairs, fn {utc, jd_tt} ->
        {:ok, cache} = Ephemeris.precompute_earth_ssb(jd_tt)
        observer_km = observer_icrf(observer_ecef, utc, jd_tt)

        nutation = Sidereal.nutation_iau2000a(jd_tt)

        Map.new(bodies, fn body ->
          {:ok, state} = Ephemeris.geocentric_state_from_cache(cache, body)
          vector = line_of_sight(state.geocentric_position_km, observer_km)
          {lon, _lat} = Ecliptic.icrf_to_true_lon_lat(vector, jd_tt, nutation)
          dec = icrf_to_declination(vector)
          {body, {lon, dec}}
        end)
      end)

    lons_by_body =
      Map.new(bodies, fn body ->
        lons = Enum.map(per_timestamp, fn ts -> ts |> Map.fetch!(body) |> elem(0) end)
        {body, lons}
      end)

    decs_by_body =
      Map.new(bodies, fn body ->
        decs = Enum.map(per_timestamp, fn ts -> ts |> Map.fetch!(body) |> elem(1) end)
        {body, decs}
      end)

    {lons_by_body, decs_by_body}
  end

  # Equatorial declination from J2000 ICRF cartesian vector (degrees).
  defp icrf_to_declination({x, y, z}) do
    r = :math.sqrt(x * x + y * y + z * z)
    :math.asin(z / r) * 180.0 / :math.pi()
  end

  # ---------------------------------------------------------------------------
  # Motion rate computation (central difference on longitude array)
  # ---------------------------------------------------------------------------

  defp compute_interval_days([_single]), do: 15 / 1440.0

  defp compute_interval_days([t1, t2 | _rest]) do
    DateTime.diff(t2, t1, :second) / 86_400.0
  end

  defp compute_motion_rates(lons_by_body, interval_days) do
    Map.new(lons_by_body, fn {body, lons} ->
      {body, rates_for_body(lons, interval_days)}
    end)
  end

  defp rates_for_body([_single], _interval_days), do: [0.0]

  defp rates_for_body(lons, interval_days) do
    arr = List.to_tuple(lons)
    n = tuple_size(arr)

    Enum.map(0..(n - 1), fn i ->
      cond do
        i == 0 ->
          Angle.signed_delta(elem(arr, 0), elem(arr, 1)) / interval_days

        i == n - 1 ->
          Angle.signed_delta(elem(arr, n - 2), elem(arr, n - 1)) / interval_days

        true ->
          Angle.signed_delta(elem(arr, i - 1), elem(arr, i + 1)) / (2.0 * interval_days)
      end
    end)
  end
end
