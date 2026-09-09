defmodule EphCore.SnapshotPipeline.Motion do
  @moduledoc """
  Stage 05: MOTION — compute per-body ecliptic longitude rates.
  """

  alias EphCore.EarthOrientation.Sidereal
  alias EphCore.Corrections.ApparentPlace
  alias EphCore.Ephemeris
  alias EphCore.Geometry.Ecliptic
  alias EphCore.SnapshotPipeline.Snapshot

  @method "central_difference_on_ecliptic_longitude_wrap_safe"

  @spec resolve(term(), boolean()) :: term()
  def resolve(snapshot, parallel? \\ false)

  def resolve(
        %Snapshot{intent: %{motion: %{enabled: true, dt_minutes: dt_minutes}}} = snapshot,
        parallel?
      ) do
    motion = compute_motion(snapshot, dt_minutes, parallel?)
    %{snapshot | motion: motion}
  end

  def resolve(%Snapshot{} = snapshot, _parallel?), do: snapshot

  defp compute_motion(snapshot, dt_minutes, true = _parallel?) do
    compute_motion_parallel(snapshot, dt_minutes)
  end

  defp compute_motion(snapshot, dt_minutes, false = _parallel?) do
    compute_motion_sequential(snapshot, dt_minutes)
  end

  defp compute_motion_sequential(
         %Snapshot{
           intent: %{
             targets: targets,
             models: %{ecliptic_frame: frame},
             corrections: corrections,
             utc: utc
           },
           astronomical_time: %{jd_tt: jd_tt}
         },
         dt_minutes
       ) do
    dt_days = dt_minutes / 1440.0
    jd_prev = jd_tt - dt_days
    jd_next = jd_tt + dt_days

    {:ok, cache_prev} = Ephemeris.precompute_earth_ssb(jd_prev)
    {:ok, cache_next} = Ephemeris.precompute_earth_ssb(jd_next)
    nutation_offsets = nutation_for_motion_offsets(frame, jd_prev, jd_next)
    apparent_frames = build_apparent_frames(corrections, utc, dt_minutes)

    targets
    |> Enum.map(fn target ->
      compute_target_motion(
        target,
        cache_prev,
        cache_next,
        frame,
        jd_prev,
        jd_next,
        dt_minutes,
        nutation_offsets,
        apparent_frames
      )
    end)
    |> Map.new()
  end

  defp compute_motion_parallel(
         %Snapshot{
           intent: %{
             targets: targets,
             models: %{ecliptic_frame: frame},
             corrections: corrections,
             utc: utc
           },
           astronomical_time: %{jd_tt: jd_tt}
         },
         dt_minutes
       ) do
    dt_days = dt_minutes / 1440.0
    jd_prev = jd_tt - dt_days
    jd_next = jd_tt + dt_days

    {:ok, cache_prev} = Ephemeris.precompute_earth_ssb(jd_prev)
    {:ok, cache_next} = Ephemeris.precompute_earth_ssb(jd_next)
    nutation_offsets = nutation_for_motion_offsets(frame, jd_prev, jd_next)
    apparent_frames = build_apparent_frames(corrections, utc, dt_minutes)

    targets
    |> Task.async_stream(
      fn target ->
        compute_target_motion(
          target,
          cache_prev,
          cache_next,
          frame,
          jd_prev,
          jd_next,
          dt_minutes,
          nutation_offsets,
          apparent_frames
        )
      end,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
    |> Map.new()
  end

  defp build_apparent_frames(corrections, utc, dt_minutes) do
    if Map.get(corrections, :aberration, false) and Map.get(corrections, :light_time, false) do
      utc_prev = DateTime.add(utc, -dt_minutes * 60, :second)
      utc_next = DateTime.add(utc, dt_minutes * 60, :second)
      jd_tt_prev = ApparentPlace.utc_to_jd_tt(utc_prev)
      jd_tt_next = ApparentPlace.utc_to_jd_tt(utc_next)
      nutation_prev = ApparentPlace.nutation_at(jd_tt_prev)
      nutation_next = ApparentPlace.nutation_at(jd_tt_next)
      earth_vel_prev = ApparentPlace.earth_velocity_at(jd_tt_prev)
      earth_vel_next = ApparentPlace.earth_velocity_at(jd_tt_next)
      zero_observer = %{lat: 0.0, lon: 0.0, height: 0.0}

      frame_prev =
        ApparentPlace.frame(utc_prev, zero_observer,
          nutation: nutation_prev,
          earth_velocity: earth_vel_prev
        )

      frame_next =
        ApparentPlace.frame(utc_next, zero_observer,
          nutation: nutation_next,
          earth_velocity: earth_vel_next
        )

      {frame_prev, frame_next}
    else
      nil
    end
  end

  defp nutation_for_motion_offsets(:true_of_date, jd_prev, jd_next) do
    {Sidereal.nutation_iau2000a(jd_prev), Sidereal.nutation_iau2000a(jd_next)}
  end

  defp nutation_for_motion_offsets(_frame, _jd_prev, _jd_next), do: {nil, nil}

  defp compute_target_motion(
         target,
         cache_prev,
         cache_next,
         frame,
         jd_prev,
         jd_next,
         dt_minutes,
         {nut_prev, nut_next},
         apparent_frames
       ) do
    {:ok, prev_state} = Ephemeris.geocentric_state_from_cache(cache_prev, target)
    {:ok, next_state} = Ephemeris.geocentric_state_from_cache(cache_next, target)

    lon_prev = ecliptic_lon(prev_state.geocentric_position_km, frame, jd_prev, nut_prev)
    lon_next = ecliptic_lon(next_state.geocentric_position_km, frame, jd_next, nut_next)

    delta = wrap_delta(lon_next - lon_prev)
    rate = delta * (720.0 / dt_minutes)

    base_motion = %{
      ecliptic_lon_rate_deg_per_day: rate,
      retrograde: rate < 0,
      dt_minutes: dt_minutes,
      frame: frame,
      method: @method
    }

    motion =
      case apparent_frames do
        {ap_frame_prev, ap_frame_next} ->
          {ap_lon_prev, _} = ApparentPlace.apparent_lon_lat(ap_frame_prev, target).geocentric
          {ap_lon_next, _} = ApparentPlace.apparent_lon_lat(ap_frame_next, target).geocentric
          ap_delta = wrap_delta(ap_lon_next - ap_lon_prev)
          ap_rate = ap_delta * (720.0 / dt_minutes)
          Map.put(base_motion, :apparent_geocentric_ecliptic_lon_rate_deg_per_day, ap_rate)

        nil ->
          base_motion
      end

    {target, motion}
  end

  defp ecliptic_lon(position_km, :j2000, _jd_tt, _nutation) do
    {lon, _lat} = Ecliptic.icrf_to_j2000_lon_lat(position_km)
    lon
  end

  defp ecliptic_lon(position_km, :mean_of_date, jd_tt, _nutation) do
    {lon, _lat} = Ecliptic.icrf_to_mean_lon_lat(position_km, jd_tt)
    lon
  end

  defp ecliptic_lon(position_km, :true_of_date, jd_tt, nutation) when is_tuple(nutation) do
    {lon, _lat} = Ecliptic.icrf_to_true_lon_lat(position_km, jd_tt, nutation)
    lon
  end

  defp ecliptic_lon(position_km, :true_of_date, jd_tt, _nutation) do
    {lon, _lat} = Ecliptic.icrf_to_true_lon_lat(position_km, jd_tt)
    lon
  end

  @doc false
  def wrap_delta(delta) when delta > 180.0, do: delta - 360.0
  def wrap_delta(delta) when delta < -180.0, do: delta + 360.0
  def wrap_delta(delta), do: delta
end
