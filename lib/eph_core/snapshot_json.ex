defmodule EphCore.SnapshotJSON do
  @moduledoc false

  alias AstroUtils.Angle
  alias EphCore.Geometry.CelestialSphere
  alias EphCore.SnapshotPipeline.Observation

  def show(%{observation: %Observation{} = observation}) do
    %{
      datetime: observation.intent.utc,
      jd_tt: observation.epoch.jd_tt,
      observer: observation.intent.observer,
      positions: format_positions(observation),
      geometry: format_geometry(observation)
    }
  end

  defp format_positions(
         %Observation{bodies: bodies, solar_system_positions: solar_positions, motion: motion} =
           observation
       ) do
    # Compute LST once for hour angle calculations
    lst_deg = compute_lst(observation)
    motion = motion || %{}

    targets =
      bodies
      |> Map.keys()
      |> Enum.concat(Map.keys(solar_positions))
      |> Enum.uniq()

    Map.new(targets, fn target ->
      {Atom.to_string(target),
       build_position_payload(
         %{
           ecliptic: format_ecliptic(solar_positions[target], bodies[target]),
           equatorial: format_equatorial(solar_positions[target], bodies[target], lst_deg),
           sky: format_sky(bodies[target])
         },
         motion[target]
       )}
    end)
  end

  defp compute_lst(%Observation{} = observation) do
    sidereal_time_type = sidereal_time_type(observation)

    east_horizon =
      EphCore.Geometry.Horizon.ecliptic_lon_at_east_horizon(
        observation.epoch.jd_tt,
        observation.intent.observer.lat_deg,
        observation.intent.observer.lon_deg,
        sidereal_time_type: sidereal_time_type,
        obliquity_model: observation.intent.models.ecliptic_frame,
        jd_ut1: observation.epoch.jd_ut1
      )

    east_horizon.lst
  end

  defp format_ecliptic(nil, _sky), do: %{}

  defp format_ecliptic(%{ecliptic_longitude: _} = body, sky) do
    base = %{
      ecliptic_longitude: body.ecliptic_longitude,
      ecliptic_latitude: body.ecliptic_latitude,
      distance_km: body.geocentric_range_km
    }

    base =
      if sky && sky.topocentric_ecliptic_longitude do
        Map.merge(base, %{
          topocentric_ecliptic_longitude: sky.topocentric_ecliptic_longitude,
          topocentric_ecliptic_latitude: sky.topocentric_ecliptic_latitude
        })
      else
        base
      end

    if body.apparent_geocentric_ecliptic_longitude != nil do
      Map.merge(base, %{
        apparent_geocentric_ecliptic_longitude: body.apparent_geocentric_ecliptic_longitude,
        apparent_geocentric_ecliptic_latitude: body.apparent_geocentric_ecliptic_latitude
      })
    else
      base
    end
  end

  defp format_ecliptic(_body, _sky), do: %{}

  defp format_equatorial(nil, _sky_position, _lst_deg), do: %{}

  defp format_equatorial(%{right_ascension: _} = solar_pos, sky_pos, lst_deg) do
    geocentric_ha = Angle.normalize_360(lst_deg - solar_pos.right_ascension)

    topocentric_ha =
      if sky_pos && sky_pos.topocentric_right_ascension do
        Angle.normalize_360(lst_deg - sky_pos.topocentric_right_ascension)
      else
        nil
      end

    %{
      right_ascension: solar_pos.right_ascension,
      declination: solar_pos.declination,
      hour_angle_geocentric_deg: geocentric_ha,
      hour_angle_topocentric_deg: topocentric_ha
    }
  end

  defp format_equatorial(_body, _sky_position, _lst_deg), do: %{}

  defp format_sky(nil), do: %{}

  defp format_sky(body) do
    %{
      altitude_deg: body.altitude_deg,
      azimuth_deg: body.azimuth_deg,
      distance_km: body.topocentric_range_km
    }
  end

  defp format_geometry(%Observation{} = observation) do
    sidereal_time_type = sidereal_time_type(observation)

    east_horizon =
      EphCore.Geometry.Horizon.ecliptic_lon_at_east_horizon(
        observation.epoch.jd_tt,
        observation.intent.observer.lat_deg,
        observation.intent.observer.lon_deg,
        sidereal_time_type: sidereal_time_type,
        obliquity_model: observation.intent.models.ecliptic_frame,
        jd_ut1: observation.epoch.jd_ut1
      )

    meridian =
      EphCore.Geometry.Horizon.ecliptic_lon_on_meridian(
        observation.epoch.jd_tt,
        observation.intent.observer.lon_deg,
        sidereal_time_type: sidereal_time_type,
        obliquity_model: observation.intent.models.ecliptic_frame,
        jd_ut1: observation.epoch.jd_ut1
      )

    ring_geometry = CelestialSphere.geometry_payload(observation)

    %{
      lst: east_horizon.lst,
      obliquity: obliquity_from_models(observation),
      ecliptic_frame: observation.intent.models.ecliptic_frame,
      east_horizon_ecliptic_longitude: east_horizon.east_horizon_ecliptic_longitude,
      meridian_longitude: meridian.meridian_ecliptic_longitude
    }
    |> Map.merge(ring_geometry)
  end

  defp build_position_payload(payload, nil), do: payload

  defp build_position_payload(payload, motion) do
    Map.put(payload, :motion, format_motion(motion))
  end

  defp format_motion(
         %{
           ecliptic_lon_rate_deg_per_day: _,
           retrograde: _,
           dt_minutes: _,
           frame: _,
           method: _
         } = motion
       ) do
    motion
  end

  defp obliquity_from_models(observation) do
    case observation.intent.models.ecliptic_frame do
      :true_of_date ->
        EphCore.EarthOrientation.Sidereal.true_obliquity_iau2006(observation.epoch.jd_tt)

      :mean_of_date ->
        EphCore.EarthOrientation.Sidereal.mean_obliquity_iau2006(observation.epoch.jd_tt)

      _ ->
        23.4392911
    end
  end

  defp sidereal_time_type(%Observation{intent: %{models: %{earth_orientation: :gmst}}}), do: :mean
  defp sidereal_time_type(_observation), do: :apparent
end
