defmodule EphCore.SnapshotPipeline.SolarSystemPosition do
  @moduledoc """
  Stage 04: SOLAR_SYSTEM_POSITION — query the ephemeris for body positions.
  """

  alias EphCore.Corrections.ApparentPlace
  alias EphCore.Ephemeris
  alias AstroUtils.{Angle, Vector}
  alias EphCore.Geometry.Ecliptic
  alias EphCore.SnapshotPipeline.{AstronomicalTime, Snapshot}
  alias EphCore.Telemetry

  defstruct [
    :target,
    :geocentric_position_km,
    :geocentric_range_km,
    :right_ascension,
    :declination,
    :ecliptic_longitude,
    :ecliptic_latitude,
    :ecliptic_frame,
    :apparent_geocentric_ecliptic_longitude,
    :apparent_geocentric_ecliptic_latitude,
    :frame,
    :query_seconds_past_j2000,
    :computation_time_us
  ]

  @type t :: %__MODULE__{
          target: atom(),
          geocentric_position_km: {float(), float(), float()},
          geocentric_range_km: float(),
          right_ascension: float() | nil,
          declination: float() | nil,
          ecliptic_longitude: float() | nil,
          ecliptic_latitude: float() | nil,
          ecliptic_frame: atom() | nil,
          apparent_geocentric_ecliptic_longitude: float() | nil,
          apparent_geocentric_ecliptic_latitude: float() | nil,
          frame: atom(),
          query_seconds_past_j2000: float(),
          computation_time_us: non_neg_integer()
        }

  @spec resolve(term(), atom()) :: t()
  def resolve(
        %Snapshot{astronomical_time: %AstronomicalTime{jd_tt: jd_tt}} = snapshot,
        target
      )
      when is_atom(target) do
    start = System.monotonic_time(:microsecond)
    Telemetry.stage_start(:solar_system_position)

    {:ok, state} = Ephemeris.geocentric_state(jd_tt, target)

    duration = System.monotonic_time(:microsecond) - start
    Telemetry.stage_stop(:solar_system_position, duration, %{target: target})

    snapshot
    |> build_struct(state, target, duration)
    |> maybe_add_ecliptic(snapshot)
    |> maybe_add_apparent_geocentric(snapshot)
  end

  @spec resolve_from_cache(
          term(),
          atom(),
          %{seconds: float(), earth_ssb: {float(), float(), float()}}
        ) :: t()
  def resolve_from_cache(
        %Snapshot{} = snapshot,
        target,
        %{seconds: seconds} = cache
      )
      when is_atom(target) and is_float(seconds) do
    start = System.monotonic_time(:microsecond)
    Telemetry.stage_start(:solar_system_position)

    {:ok, state} = Ephemeris.geocentric_state_from_cache(cache, target)

    duration = System.monotonic_time(:microsecond) - start
    Telemetry.stage_stop(:solar_system_position, duration, %{target: target})

    snapshot
    |> build_struct(state, target, duration)
    |> maybe_add_ecliptic(snapshot)
    |> maybe_add_apparent_geocentric(snapshot)
  end

  defp build_struct(_snapshot, state, target, duration) do
    geocentric_range_km =
      if is_number(state.geocentric_range_km) do
        state.geocentric_range_km
      else
        Vector.magnitude(state.geocentric_position_km)
      end

    {right_ascension, declination} = ra_dec_from_icrf(state.geocentric_position_km)

    %__MODULE__{
      target: target,
      geocentric_position_km: state.geocentric_position_km,
      geocentric_range_km: geocentric_range_km,
      right_ascension: right_ascension,
      declination: declination,
      ecliptic_longitude: nil,
      ecliptic_latitude: nil,
      ecliptic_frame: nil,
      apparent_geocentric_ecliptic_longitude: nil,
      apparent_geocentric_ecliptic_latitude: nil,
      frame: state.frame,
      query_seconds_past_j2000: state.query_seconds_past_j2000,
      computation_time_us: duration
    }
  end

  defp maybe_add_apparent_geocentric(
         %__MODULE__{} = position,
         %Snapshot{intent: intent}
       ) do
    if Map.get(intent.corrections, :aberration, false) and
         Map.get(intent.corrections, :light_time, false) do
      utc = intent.utc
      apparent_frame = ApparentPlace.frame(utc, %{lat: 0.0, lon: 0.0, height: 0.0})

      %{geocentric: {geo_lon, geo_lat}} =
        ApparentPlace.apparent_lon_lat(apparent_frame, position.target)

      %__MODULE__{
        position
        | apparent_geocentric_ecliptic_longitude: geo_lon,
          apparent_geocentric_ecliptic_latitude: geo_lat
      }
    else
      position
    end
  end

  defp ra_dec_from_icrf({x, y, z}) do
    ra = Angle.atan2_lon(y, x)
    r = :math.sqrt(x * x + y * y + z * z)
    dec = :math.asin(z / r) * 180.0 / :math.pi()

    {ra, dec}
  end

  defp maybe_add_ecliptic(
         %__MODULE__{} = position,
         %Snapshot{intent: %{models: %{ecliptic_frame: :j2000}}}
       ) do
    {lon, lat} = Ecliptic.icrf_to_j2000_lon_lat(position.geocentric_position_km)

    %__MODULE__{
      position
      | ecliptic_longitude: lon,
        ecliptic_latitude: lat,
        ecliptic_frame: :j2000
    }
  end

  defp maybe_add_ecliptic(
         %__MODULE__{} = position,
         %Snapshot{
           intent: %{models: %{ecliptic_frame: :mean_of_date}},
           astronomical_time: %{jd_tt: jd_tt}
         }
       ) do
    {lon, lat} = Ecliptic.icrf_to_mean_lon_lat(position.geocentric_position_km, jd_tt)

    %__MODULE__{
      position
      | ecliptic_longitude: lon,
        ecliptic_latitude: lat,
        ecliptic_frame: :mean_of_date
    }
  end

  defp maybe_add_ecliptic(
         %__MODULE__{} = position,
         %Snapshot{
           intent: %{models: %{ecliptic_frame: :true_of_date}},
           astronomical_time: %{jd_tt: jd_tt},
           true_of_date_nutation: nutation
         }
       )
       when is_tuple(nutation) do
    {lon, lat} = Ecliptic.icrf_to_true_lon_lat(position.geocentric_position_km, jd_tt, nutation)

    %__MODULE__{
      position
      | ecliptic_longitude: lon,
        ecliptic_latitude: lat,
        ecliptic_frame: :true_of_date
    }
  end

  defp maybe_add_ecliptic(
         %__MODULE__{} = position,
         %Snapshot{
           intent: %{models: %{ecliptic_frame: :true_of_date}},
           astronomical_time: %{jd_tt: jd_tt}
         }
       ) do
    {lon, lat} = Ecliptic.icrf_to_true_lon_lat(position.geocentric_position_km, jd_tt)

    %__MODULE__{
      position
      | ecliptic_longitude: lon,
        ecliptic_latitude: lat,
        ecliptic_frame: :true_of_date
    }
  end

  defp maybe_add_ecliptic(%__MODULE__{} = position, _snapshot), do: position
end
