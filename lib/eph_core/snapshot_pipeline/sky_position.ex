defmodule EphCore.SnapshotPipeline.SkyPosition do
  @moduledoc """
  Stage 06: SKY_POSITION — project topocentric vectors onto the local sky.
  """

  alias AstroUtils.Angle
  alias EphCore.Geometry.{Ecliptic, Horizontal}

  alias EphCore.SnapshotPipeline.{
    ObserverLineOfSight,
    ObserverPosition,
    Snapshot,
    SolarSystemPosition
  }

  alias EphCore.Telemetry

  defstruct [
    :target,
    :altitude_deg,
    :azimuth_deg,
    :azimuth_convention,
    :geometric_altitude_deg,
    :apparent_altitude_deg,
    :refraction_applied,
    :refraction_correction_deg,
    :topocentric_range_km,
    :geocentric_range_km,
    :topocentric_right_ascension,
    :topocentric_declination,
    :topocentric_ecliptic_longitude,
    :topocentric_ecliptic_latitude
  ]

  @type t :: %__MODULE__{
          target: atom(),
          altitude_deg: float(),
          azimuth_deg: float(),
          azimuth_convention: atom(),
          geometric_altitude_deg: float(),
          apparent_altitude_deg: float(),
          refraction_applied: boolean(),
          refraction_correction_deg: float(),
          topocentric_range_km: float(),
          geocentric_range_km: float(),
          topocentric_right_ascension: float(),
          topocentric_declination: float(),
          topocentric_ecliptic_longitude: float() | nil,
          topocentric_ecliptic_latitude: float() | nil
        }

  @spec resolve(term(), ObserverLineOfSight.t(), SolarSystemPosition.t()) :: t()
  def resolve(
        %Snapshot{observer_position: %ObserverPosition{local_basis: local_basis}} = snapshot,
        %ObserverLineOfSight{} = line_of_sight,
        %SolarSystemPosition{} = solar_system_position
      ) do
    start = System.monotonic_time(:microsecond)
    Telemetry.stage_start(:sky_position)

    {altitude_deg, azimuth_deg} =
      Horizontal.alt_az_from_direction(line_of_sight.direction_unit, local_basis)

    # Compute topocentric RA/Dec from ICRF topocentric vector
    {topo_ra, topo_dec} = ra_dec_from_icrf(line_of_sight.topocentric_position_km)

    # Compute topocentric ecliptic longitude/latitude from topocentric ICRF vector
    {topo_ecl_lon, topo_ecl_lat} = compute_topocentric_ecliptic(snapshot, line_of_sight)

    duration = System.monotonic_time(:microsecond) - start
    Telemetry.stage_stop(:sky_position, duration, %{target: line_of_sight.target})

    %__MODULE__{
      target: line_of_sight.target,
      altitude_deg: altitude_deg,
      azimuth_deg: azimuth_deg,
      azimuth_convention: :north_clockwise,
      geometric_altitude_deg: altitude_deg,
      apparent_altitude_deg: altitude_deg,
      refraction_applied: false,
      refraction_correction_deg: 0.0,
      topocentric_range_km: line_of_sight.topocentric_range_km,
      geocentric_range_km: solar_system_position.geocentric_range_km,
      topocentric_right_ascension: topo_ra,
      topocentric_declination: topo_dec,
      topocentric_ecliptic_longitude: topo_ecl_lon,
      topocentric_ecliptic_latitude: topo_ecl_lat
    }
  end

  # Compute RA/Dec from ICRF position vector (same formula as SolarSystemPosition)
  defp ra_dec_from_icrf({x, y, z}) do
    ra = Angle.atan2_lon(y, x)
    r = :math.sqrt(x * x + y * y + z * z)
    dec = :math.asin(z / r) * 180.0 / :math.pi()

    {ra, dec}
  end

  # Compute topocentric ecliptic lon/lat by routing the topocentric ICRF vector
  # through the same frame as the geocentric ecliptic (set by intent.models.ecliptic_frame).
  defp compute_topocentric_ecliptic(
         %Snapshot{intent: %{models: %{ecliptic_frame: :j2000}}},
         %ObserverLineOfSight{topocentric_position_km: topo_km}
       ) do
    Ecliptic.icrf_to_j2000_lon_lat(topo_km)
  end

  defp compute_topocentric_ecliptic(
         %Snapshot{
           intent: %{models: %{ecliptic_frame: :mean_of_date}},
           astronomical_time: %{jd_tt: jd_tt}
         },
         %ObserverLineOfSight{topocentric_position_km: topo_km}
       ) do
    Ecliptic.icrf_to_mean_lon_lat(topo_km, jd_tt)
  end

  defp compute_topocentric_ecliptic(
         %Snapshot{
           intent: %{models: %{ecliptic_frame: :true_of_date}},
           astronomical_time: %{jd_tt: jd_tt},
           true_of_date_nutation: nutation
         },
         %ObserverLineOfSight{topocentric_position_km: topo_km}
       )
       when is_tuple(nutation) do
    Ecliptic.icrf_to_true_lon_lat(topo_km, jd_tt, nutation)
  end

  defp compute_topocentric_ecliptic(
         %Snapshot{
           intent: %{models: %{ecliptic_frame: :true_of_date}},
           astronomical_time: %{jd_tt: jd_tt}
         },
         %ObserverLineOfSight{topocentric_position_km: topo_km}
       ) do
    Ecliptic.icrf_to_true_lon_lat(topo_km, jd_tt)
  end

  defp compute_topocentric_ecliptic(_snapshot, _los), do: {nil, nil}
end
