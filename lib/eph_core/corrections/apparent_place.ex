defmodule EphCore.Corrections.ApparentPlace do
  @moduledoc """
  Apparent-place correction: light-time retardation + annual aberration.

  Applies the two corrections that distinguish apparent place from the astrometric
  (geometric) position computed by the snapshot pipeline (it omits gravitational
  deflection, which is negligible):

  1. **Light-time** — the body is seen where it *was* when the light left it.
     Iterate `tau = range / c`, re-evaluating the body's barycentric position at
     the retarded epoch `jd_tt - tau` (1–2 rounds converge well inside a second).
  2. **Annual aberration** — the apparent direction is tilted toward the
     observer's velocity. We use Earth's barycentric velocity (the dominant
     ~20.5" annual term; the ~0.3" diurnal term is dropped) and Skyfield's exact
     relativistic `add_aberration` formula so the two engines agree.

  The observer geometry (ECEF → inertial rotation and the local east/north/up
  basis) is built from the **same** IAU 2006/2000A precession-nutation matrix and
  local-basis definition the validated snapshot pipeline uses
  (`EphCore.SnapshotPipeline.EarthOrientation` with `:gast` + precession-nutation,
  and `EphCore.Geometry.Horizontal.local_basis/3`).

  ## Usage

      frame = ApparentPlace.frame(utc_datetime, %{lat: ..., lon: ..., height: ...})
      %{alt_deg: alt, az_deg: az, hour_angle_deg: ha, range_km: r} =
        ApparentPlace.look(frame, :moon)

  Per-timestamp work shared across all bodies (earth state, Earth velocity,
  nutation, observer position/basis, sidereal time) is computed once in
  `frame/2`; per-body light-time + aberration is computed in `look/2`.
  """

  alias AstroUtils.{Angle, Matrix3, Vector}
  alias EphCore.AstronomicalTime.{JulianDay, TerrestrialTime, UniversalTimeOne}
  alias EphCore.EarthOrientation.Sidereal
  alias EphCore.Ephemeris
  alias EphCore.Geometry.{Ecliptic, Geodetic, Horizontal}

  @c_km_per_s 299_792.458
  @c_km_per_day @c_km_per_s * 86_400.0
  # Central-difference half-step for Earth's barycentric velocity (days).
  @velocity_half_step_days 0.05
  # Light-time iterations: range barely changes after the first, two is plenty.
  @light_time_iterations 2

  @type observer :: %{optional(atom()) => float()}

  @type time_context :: %{
          utc: DateTime.t(),
          jd_tt: float(),
          cache: map(),
          earth_ssb_km: Vector.t(),
          earth_velocity_km_per_day: Vector.t(),
          nutation: {float(), float()},
          eq_of_date_matrix: Matrix3.t(),
          gast_deg: float(),
          ecef_to_icrf: Matrix3.t()
        }

  @type frame :: %{
          utc: DateTime.t(),
          jd_tt: float(),
          cache: map(),
          earth_ssb_km: Vector.t(),
          earth_velocity_km_per_day: Vector.t(),
          nutation: {float(), float()},
          observer_icrf_km: Vector.t(),
          local_basis: Horizontal.local_basis(),
          eq_of_date_matrix: Matrix3.t(),
          last_deg: float()
        }

  @type look :: %{
          alt_deg: float(),
          az_deg: float(),
          hour_angle_deg: float(),
          declination_deg: float(),
          range_km: float()
        }

  @type geocentric_apparent :: %{
          body: atom(),
          geocentric_icrf_km: Vector.t(),
          earth_velocity_km_per_day: Vector.t()
        }

  @doc """
  Precompute the per-timestamp Earth context that can be shared across observers and bodies.

  ## Options

  - `:nutation` — reuse a `{Δψ, Δε}` pair instead of summing the IAU 2000A series.
  - `:earth_velocity` — reuse an Earth barycentric velocity vector (km/day).

  Both terms vary negligibly over the ~1-hour root-finding brackets, so the
  almanac scanner computes them once per event and threads them through every
  refinement frame to avoid re-summing the 106-term nutation series and the
  extra SPK velocity evaluations on the hot path.
  """
  @spec time_context(DateTime.t(), keyword()) :: time_context()
  def time_context(%DateTime{} = utc, opts \\ []) do
    jd_tt = datetime_to_jd_tt(utc)
    {:ok, cache} = Ephemeris.precompute_earth_ssb_fast(jd_tt)
    nutation = Keyword.get_lazy(opts, :nutation, fn -> Sidereal.nutation_iau2000a(jd_tt) end)

    earth_velocity =
      Keyword.get_lazy(opts, :earth_velocity, fn -> earth_velocity_km_per_day(jd_tt) end)

    eq_of_date_matrix = Sidereal.true_precession_matrix_iau2006(jd_tt, nutation)
    gast_deg = apparent_sidereal_time(utc, jd_tt, 0.0)
    gast_rad = Angle.deg_to_rad(gast_deg)

    ecef_to_icrf =
      Matrix3.multiply(Matrix3.transpose(eq_of_date_matrix), Matrix3.rot_z(gast_rad))

    %{
      utc: utc,
      jd_tt: jd_tt,
      cache: cache,
      earth_ssb_km: cache.earth_ssb,
      earth_velocity_km_per_day: earth_velocity,
      nutation: nutation,
      eq_of_date_matrix: eq_of_date_matrix,
      gast_deg: gast_deg,
      ecef_to_icrf: ecef_to_icrf
    }
  end

  @spec frame(DateTime.t(), observer()) :: frame()
  def frame(%DateTime{} = utc, observer), do: frame(utc, observer, [])

  @doc """
  Add observer-local geometry to a reusable `time_context/2`.
  """
  @spec frame(time_context(), observer()) :: frame()
  def frame(%{utc: %DateTime{}} = context, observer) do
    {lat, lon, height} = observer_geodetic(observer)
    last_deg = Sidereal.normalize_angle(context.gast_deg + lon)

    # `eq_of_date_matrix` maps ICRF → true-equator-of-date (the direction the
    # RA/Dec path uses). Going the other way, ECEF → ICRF, is
    # `transpose(eq_of_date) · rot_z(GAST)`: rotate ECEF about the pole by GAST
    # into the true equinox of date, then de-rotate precession-nutation back to
    # ICRF. Using the un-transposed matrix here tilts the whole local frame by
    # the precession-nutation angle (~0.5°), which is why the basis-derived
    # altitude disagreed with the (correct) hour-angle/declination altitude.
    observer_icrf_km =
      Matrix3.multiply_vector(context.ecef_to_icrf, Geodetic.to_ecef_km(lat, lon, height))

    %{
      utc: context.utc,
      jd_tt: context.jd_tt,
      cache: context.cache,
      earth_ssb_km: context.earth_ssb_km,
      earth_velocity_km_per_day: context.earth_velocity_km_per_day,
      nutation: context.nutation,
      observer_icrf_km: observer_icrf_km,
      local_basis: Horizontal.local_basis(lat, lon, context.ecef_to_icrf),
      eq_of_date_matrix: context.eq_of_date_matrix,
      last_deg: last_deg
    }
  end

  @spec frame(DateTime.t(), observer(), keyword()) :: frame()
  def frame(%DateTime{} = utc, observer, opts) do
    utc
    |> time_context(opts)
    |> frame(observer)
  end

  @doc "Compute the IAU 2000A nutation `{Δψ, Δε}` (radians) at `jd_tt`."
  @spec nutation_at(float()) :: {float(), float()}
  def nutation_at(jd_tt), do: Sidereal.nutation_iau2000a(jd_tt)

  @doc "Earth barycentric velocity (km/day) at `jd_tt`, via central difference."
  @spec earth_velocity_at(float()) :: Vector.t()
  def earth_velocity_at(jd_tt), do: earth_velocity_km_per_day(jd_tt)

  @doc "Convert a UTC `DateTime` to its Terrestrial-Time Julian Date."
  @spec utc_to_jd_tt(DateTime.t()) :: float()
  def utc_to_jd_tt(%DateTime{} = utc), do: datetime_to_jd_tt(utc)

  @doc """
  Apparent topocentric look angles for `body` from a precomputed `frame/2`.

  Returns altitude, azimuth (from North through East), local hour angle in
  `(-180, 180]` (0 at upper transit), declination, and topocentric range — all
  light-time- and aberration-corrected to match Skyfield's `.apparent().altaz()`.
  """
  @spec look(frame(), atom()) :: look()
  def look(frame, body) do
    frame
    |> geocentric_apparent(body)
    |> project(frame)
  end

  @doc """
  Compute the observer-independent apparent-place state for one `{time, body}`.

  This is not a finished topocentric apparent direction: observer subtraction
  happens before the final aberration/projection pass in `project/2`.
  """
  @spec geocentric_apparent(time_context() | frame(), atom()) :: geocentric_apparent()
  def geocentric_apparent(context, body) do
    %{
      body: body,
      geocentric_icrf_km: light_time_corrected_geocentric(context, body),
      earth_velocity_km_per_day: context.earth_velocity_km_per_day
    }
  end

  @doc """
  Project a shared geocentric apparent-place state into one observer's local sky.
  """
  @spec project(geocentric_apparent(), frame()) :: look()
  def project(geocentric_apparent, frame) do
    topocentric = Vector.subtract(geocentric_apparent.geocentric_icrf_km, frame.observer_icrf_km)
    apparent = add_aberration(topocentric, geocentric_apparent.earth_velocity_km_per_day)

    {alt_deg, az_deg} = Horizontal.alt_az_from_direction(apparent, frame.local_basis)
    {ha_deg, dec_deg} = hour_angle_and_dec(apparent, frame)

    %{
      alt_deg: alt_deg,
      az_deg: az_deg,
      hour_angle_deg: ha_deg,
      declination_deg: dec_deg,
      range_km: Vector.magnitude(topocentric)
    }
  end

  @doc """
  Apparent ecliptic longitude/latitude for `body` in both geocentric and topocentric variants.

  Geocentric: light-time correction + annual aberration on the geocentric ICRF vector; no
  observer subtraction. Matches the almanac-standard apparent geocentric position.

  Topocentric: additionally subtracts the observer's geocentric position before aberration,
  yielding standard observer-corrected apparent ecliptic coordinates.
  """
  @spec apparent_lon_lat(frame(), atom()) :: %{
          geocentric: {float(), float()},
          topocentric: {float(), float()}
        }
  def apparent_lon_lat(frame, body) do
    geocentric_vec = geocentric_apparent(frame, body).geocentric_icrf_km
    geo_apparent = add_aberration(geocentric_vec, frame.earth_velocity_km_per_day)
    {geo_lon, geo_lat} = Ecliptic.icrf_to_true_lon_lat(geo_apparent, frame.jd_tt, frame.nutation)

    topo_vec = Vector.subtract(geocentric_vec, frame.observer_icrf_km)
    topo_apparent = add_aberration(topo_vec, frame.earth_velocity_km_per_day)

    {topo_lon, topo_lat} =
      Ecliptic.icrf_to_true_lon_lat(topo_apparent, frame.jd_tt, frame.nutation)

    %{
      geocentric: {geo_lon, geo_lat},
      topocentric: {topo_lon, topo_lat}
    }
  end

  @doc "Speed of light used by the apparent-place pass, in km/day."
  @spec c_km_per_day() :: float()
  def c_km_per_day, do: @c_km_per_day

  # ---------------------------------------------------------------------------
  # Light-time
  # ---------------------------------------------------------------------------

  # Geocentric apparent vector: body at the retarded (emission) epoch, Earth at
  # the reception epoch. Matches Skyfield's _correct_for_light_travel_time.
  # The reception-epoch geometric vector reuses the frame's shared ephemeris
  # cache (no extra SPK precompute); only the emission epochs re-evaluate.
  defp light_time_corrected_geocentric(frame, body) do
    earth = frame.earth_ssb_km
    {:ok, state} = Ephemeris.geocentric_state_from_cache_fast(frame.cache, body)
    initial = state.geocentric_position_km

    Enum.reduce(1..@light_time_iterations, initial, fn _i, geo_vec ->
      tau_days = Vector.magnitude(geo_vec) / @c_km_per_day
      Vector.subtract(body_ssb_km(frame.jd_tt - tau_days, body), earth)
    end)
  end

  # Barycentric (SSB) position of a body at the retarded epoch jd_tt. Queries the
  # body→SSB chain directly (planet = one SPK call) instead of recomputing
  # Earth/EMB state only to subtract and re-add it. Moon special handling is
  # preserved inside `Ephemeris.body_ssb_km/2`.
  defp body_ssb_km(jd_tt, body) do
    {:ok, ssb} = Ephemeris.body_ssb_km_fast(jd_tt, body)
    ssb
  end

  # ---------------------------------------------------------------------------
  # Aberration (Skyfield's relativistic add_aberration, ported to km / km·day⁻¹)
  # ---------------------------------------------------------------------------

  defp add_aberration(position, velocity) do
    range = Vector.magnitude(position)
    vemag = Vector.magnitude(velocity)

    if range == 0.0 or vemag == 0.0 do
      position
    else
      beta = vemag / @c_km_per_day
      cosd = Vector.dot(position, velocity) / (range * vemag)
      gammai = :math.sqrt(1.0 - beta * beta)
      p = beta * cosd
      light_time = range / @c_km_per_day
      q = (1.0 + p / (1.0 + gammai)) * light_time
      r = 1.0 + p

      position
      |> Vector.scale(gammai)
      |> Vector.add(Vector.scale(velocity, q))
      |> Vector.scale(1.0 / r)
    end
  end

  # ---------------------------------------------------------------------------
  # Earth barycentric velocity (central difference)
  # ---------------------------------------------------------------------------

  defp earth_velocity_km_per_day(jd_tt) do
    h = @velocity_half_step_days
    {:ok, plus} = Ephemeris.precompute_earth_ssb_fast(jd_tt + h)
    {:ok, minus} = Ephemeris.precompute_earth_ssb_fast(jd_tt - h)
    plus.earth_ssb |> Vector.subtract(minus.earth_ssb) |> Vector.scale(1.0 / (2.0 * h))
  end

  # ---------------------------------------------------------------------------
  # Hour angle / declination (true equator and equinox of date)
  # ---------------------------------------------------------------------------

  defp hour_angle_and_dec(apparent_icrf, frame) do
    {x, y, z} = Matrix3.multiply_vector(frame.eq_of_date_matrix, apparent_icrf)
    ra_deg = Angle.atan2_lon(y, x)
    r = :math.sqrt(x * x + y * y + z * z)
    dec_deg = Angle.rad_to_deg(:math.asin(z / r))
    ha_deg = Angle.signed_delta(ra_deg, frame.last_deg)
    {ha_deg, dec_deg}
  end

  # ---------------------------------------------------------------------------
  # Time / observer helpers
  # ---------------------------------------------------------------------------

  defp datetime_to_jd_tt(%DateTime{} = utc) do
    utc |> TerrestrialTime.from_utc() |> JulianDay.from_datetime()
  end

  defp apparent_sidereal_time(%DateTime{} = utc, jd_tt, lon_deg) do
    jd_utc = JulianDay.from_datetime(utc)
    mjd_utc = JulianDay.modified_julian_day(jd_utc)
    ut1_utc = UniversalTimeOne.delta_for_mjd_utc(mjd_utc)
    jd_ut1 = UniversalTimeOne.apply_delta(jd_utc, ut1_utc)
    Sidereal.normalize_angle(Sidereal.gast_iau_2006(jd_ut1, jd_tt) + lon_deg)
  end

  defp observer_geodetic(observer) do
    lat = observer[:lat] || observer[:latitude] || 0.0
    lon = observer[:lon] || observer[:longitude] || 0.0
    height = observer[:height] || observer[:elevation] || 0.0
    {lat, lon, height}
  end
end
