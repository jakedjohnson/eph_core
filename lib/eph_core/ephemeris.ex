defmodule EphCore.Ephemeris do
  @moduledoc """
  Geocentric and barycentric state vectors read straight from SPK kernels.

  This is the layer beneath `EphCore.observe/4`: it maps body atoms to NAIF IDs,
  resolves the center chains DE440s uses (barycenters for the outer planets,
  EMB for Earth and Moon, Sun-relative for Horizons asteroid kernels), and
  returns ICRF/J2000 vectors in kilometres for a Terrestrial Time Julian date.

  Requires the ephemeris kernels described in the README data setup; positions
  for a body outside the loaded kernels' coverage return `{:error, reason}`.
  """

  alias EphCore.Ephemeris.Kernels.SPK
  alias AstroUtils.Vector

  @j2000_jd 2_451_545.0

  # Asteroid NAIF IDs start at 2_000_001. Bodies in this range are stored
  # relative to Sun (center=10) in Horizons-generated SPK kernels and require
  # center-chain resolution: body_ssb = body_sun + sun_ssb.
  defguardp is_asteroid(target)
            when is_atom(target) and
                   target in [:ceres, :pallas, :juno, :vesta, :chiron]

  # NAIF IDs for DE440s bodies
  # For outer planets, we use barycenter IDs (planet + moons center of mass)
  # which is standard practice and sufficient for geocentric positions.
  # Inner planets (Mercury, Venus, Mars) have negligible moon mass so
  # barycenter ≈ planet center.
  @naif_ids %{
    # Luminaries
    sun: 10,
    moon: 301,
    # Planets (barycenter IDs for DE440s compatibility)
    mercury: 1,
    venus: 2,
    mars: 4,
    jupiter: 5,
    saturn: 6,
    uranus: 7,
    neptune: 8,
    pluto: 9,
    # Asteroids — stored relative to Sun (center=10) in Horizons-generated kernels.
    # Horizons SPK files use NAIF IDs in the format 20XXXXXX (8 digits),
    # where XXXXXX is the zero-padded 6-digit asteroid number.
    ceres: 20_000_001,
    pallas: 20_000_002,
    juno: 20_000_003,
    vesta: 20_000_004,
    chiron: 20_002_060,
    # Internal reference bodies
    earth: 399,
    ssb: 0,
    emb: 3
  }

  @spec geocentric_state(float(), atom()) ::
          {:ok,
           %{
             geocentric_position_km: {float(), float(), float()},
             geocentric_range_km: float(),
             frame: atom(),
             query_seconds_past_j2000: float()
           }}
          | {:error, term()}
  def geocentric_state(jd_tt, target) when is_float(jd_tt) and is_atom(target) do
    with {:ok, cache} <- precompute_earth_ssb(jd_tt) do
      geocentric_state_from_cache(cache, target)
    end
  end

  # Telemetry-emitting (engine) vs telemetry-free (almanac hot path) SPK query.
  @query &SPK.position_at/3
  @query_fast &SPK.position_at_fast/3

  @doc """
  Barycentric (SSB) position of `body` (km) at `jd_tt`, querying the body→SSB
  chain directly.

  Unlike `precompute_earth_ssb/1` + `geocentric_state_from_cache/2`, this skips
  reconstructing Earth/EMB state when only the body's SSB position is needed
  (e.g. the light-time retarded epoch in `EphCore.Corrections.ApparentPlace`). For a
  planet this is a single SPK query instead of three; Moon and asteroid chains
  are preserved.
  """
  @spec body_ssb_km(float(), atom()) ::
          {:ok, {float(), float(), float()}} | {:error, term()}
  def body_ssb_km(jd_tt, target) when is_float(jd_tt) and is_atom(target) do
    seconds = (jd_tt - @j2000_jd) * 86_400.0
    body_ssb_at_seconds(seconds, target, @query)
  end

  @doc "Telemetry-free `body_ssb_km/2` for the almanac hot path."
  @spec body_ssb_km_fast(float(), atom()) ::
          {:ok, {float(), float(), float()}} | {:error, term()}
  def body_ssb_km_fast(jd_tt, target) when is_float(jd_tt) and is_atom(target) do
    seconds = (jd_tt - @j2000_jd) * 86_400.0
    body_ssb_at_seconds(seconds, target, @query_fast)
  end

  # Moon is stored relative to EMB; SSB needs emb_ssb + moon_emb (no Earth term).
  defp body_ssb_at_seconds(seconds, :moon, query) do
    with {:ok, emb_ssb} <- query.(naif_id(:emb), 0, seconds),
         {:ok, moon_emb} <- query.(naif_id(:moon), naif_id(:emb), seconds) do
      {:ok, Vector.add(emb_ssb, moon_emb)}
    end
  end

  # Asteroids are stored relative to Sun (center=10): body_ssb = body_sun + sun_ssb.
  defp body_ssb_at_seconds(seconds, target, query) when is_asteroid(target) do
    with {:ok, body_sun} <- query.(naif_id(target), naif_id(:sun), seconds),
         {:ok, sun_ssb} <- query.(naif_id(:sun), 0, seconds) do
      {:ok, Vector.add(body_sun, sun_ssb)}
    end
  end

  # All other bodies are queried directly relative to SSB.
  defp body_ssb_at_seconds(seconds, target, query) do
    query.(naif_id(target), 0, seconds)
  end

  @spec precompute_earth_ssb(float()) ::
          {:ok,
           %{
             seconds: float(),
             earth_ssb: {float(), float(), float()},
             emb_ssb: {float(), float(), float()}
           }}
          | {:error, term()}
  def precompute_earth_ssb(jd_tt) when is_float(jd_tt) do
    do_precompute_earth_ssb(jd_tt, @query)
  end

  @doc "Telemetry-free `precompute_earth_ssb/1` for the almanac hot path."
  @spec precompute_earth_ssb_fast(float()) ::
          {:ok,
           %{
             seconds: float(),
             earth_ssb: {float(), float(), float()},
             emb_ssb: {float(), float(), float()}
           }}
          | {:error, term()}
  def precompute_earth_ssb_fast(jd_tt) when is_float(jd_tt) do
    do_precompute_earth_ssb(jd_tt, @query_fast)
  end

  defp do_precompute_earth_ssb(jd_tt, query) do
    seconds = (jd_tt - @j2000_jd) * 86_400.0

    with {:ok, emb_ssb} <- query.(naif_id(:emb), 0, seconds),
         {:ok, earth_emb} <- query.(naif_id(:earth), naif_id(:emb), seconds) do
      earth_ssb = Vector.add(emb_ssb, earth_emb)
      {:ok, %{seconds: seconds, earth_ssb: earth_ssb, emb_ssb: emb_ssb}}
    end
  end

  @spec geocentric_state_from_cache(
          %{
            seconds: float(),
            earth_ssb: {float(), float(), float()},
            emb_ssb: {float(), float(), float()}
          },
          atom()
        ) ::
          {:ok,
           %{
             geocentric_position_km: {float(), float(), float()},
             geocentric_range_km: float(),
             frame: atom(),
             query_seconds_past_j2000: float()
           }}
          | {:error, term()}
  def geocentric_state_from_cache(cache, target) do
    do_geocentric_state_from_cache(cache, target, @query)
  end

  @doc "Telemetry-free `geocentric_state_from_cache/2` for the almanac hot path."
  @spec geocentric_state_from_cache_fast(
          %{
            seconds: float(),
            earth_ssb: {float(), float(), float()},
            emb_ssb: {float(), float(), float()}
          },
          atom()
        ) ::
          {:ok,
           %{
             geocentric_position_km: {float(), float(), float()},
             geocentric_range_km: float(),
             frame: atom(),
             query_seconds_past_j2000: float()
           }}
          | {:error, term()}
  def geocentric_state_from_cache_fast(cache, target) do
    do_geocentric_state_from_cache(cache, target, @query_fast)
  end

  defp do_geocentric_state_from_cache(
         %{seconds: seconds, earth_ssb: earth_ssb} = cache,
         target,
         query
       )
       when is_float(seconds) and is_atom(target) do
    with {:ok, target_ssb} <- target_ssb_position(cache, target, query) do
      geocentric_position = Vector.subtract(target_ssb, earth_ssb)

      {:ok,
       %{
         geocentric_position_km: geocentric_position,
         geocentric_range_km: Vector.magnitude(geocentric_position),
         frame: :icrf,
         query_seconds_past_j2000: seconds
       }}
    end
  end

  # Moon is stored relative to EMB in DE440s, so we need to compute its SSB position
  defp target_ssb_position(%{seconds: seconds, emb_ssb: emb_ssb}, :moon, query) do
    with {:ok, moon_emb} <- query.(naif_id(:moon), naif_id(:emb), seconds) do
      {:ok, Vector.add(emb_ssb, moon_emb)}
    end
  end

  # Asteroids are stored relative to Sun (center=10) in Horizons-generated kernels.
  # Chain: body_ssb = body_sun + sun_ssb.
  defp target_ssb_position(%{seconds: seconds}, target, query) when is_asteroid(target) do
    with {:ok, body_sun} <- query.(naif_id(target), naif_id(:sun), seconds),
         {:ok, sun_ssb} <- query.(naif_id(:sun), 0, seconds) do
      {:ok, Vector.add(body_sun, sun_ssb)}
    end
  end

  # All other bodies are queried directly relative to SSB
  defp target_ssb_position(%{seconds: seconds}, target, query) do
    query.(naif_id(target), 0, seconds)
  end

  defp naif_id(target) do
    Map.fetch!(@naif_ids, target)
  end
end
