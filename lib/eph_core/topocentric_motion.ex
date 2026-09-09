defmodule EphCore.TopocentricMotion do
  @moduledoc """
  Topocentric ecliptic longitude rates (degrees/day).

  Computes rates via central difference on observer-topocentric longitudes from
  `EphCore.SnapshotPipeline.observe/4`, so the rates share the frame of a
  topocentric `EphCore.TimeSeries` grid and can refine crossings found on it.
  """

  alias EphCore.SnapshotPipeline
  alias AstroUtils.Angle

  @default_delta_minutes 30

  @doc """
  Topocentric ecliptic longitude rates (degrees/day) for each body.

  Uses central difference at `datetime ± delta_minutes`.
  """
  @spec ecliptic_lon_rates(DateTime.t(), map(), [atom()], keyword()) :: %{atom() => float()}
  def ecliptic_lon_rates(datetime, location, bodies, opts \\ []) do
    delta_minutes = Keyword.get(opts, :delta_minutes, @default_delta_minutes)
    delta_sec = delta_minutes * 60
    t_lo = DateTime.add(datetime, -delta_sec, :second)
    t_hi = DateTime.add(datetime, delta_sec, :second)

    lons_lo = topocentric_longitudes(t_lo, location, bodies)
    lons_hi = topocentric_longitudes(t_hi, location, bodies)

    Map.new(bodies, fn body ->
      deg = Angle.signed_delta(lons_lo[body], lons_hi[body])
      rate = deg / (2 * delta_minutes) * 1440.0
      {body, rate}
    end)
  end

  @doc """
  Merge topocentric longitude rates into a geocentric motion map from observe/4.

  Each body map gains `:topocentric_ecliptic_lon_rate_deg_per_day`.
  """
  @spec augment(DateTime.t(), map(), [atom()], map(), keyword()) :: %{atom() => map()}
  def augment(datetime, location, bodies, geocentric_motion, opts \\ []) do
    rates = ecliptic_lon_rates(datetime, location, bodies, opts)

    Map.new(bodies, fn body ->
      base = Map.get(geocentric_motion, body, %{})
      topo_rate = Map.get(rates, body, 0.0)

      {body,
       Map.put(base, :topocentric_ecliptic_lon_rate_deg_per_day, Float.round(topo_rate * 1.0, 6))}
    end)
  end

  defp topocentric_longitudes(datetime, location, bodies) do
    {:ok, obs} = SnapshotPipeline.observe(datetime, location, bodies)

    Map.new(obs.solar_system_positions, fn {body, pos} ->
      topo_lon = obs.bodies[body] && obs.bodies[body].topocentric_ecliptic_longitude
      {body, topo_lon || pos.ecliptic_longitude}
    end)
  end
end
