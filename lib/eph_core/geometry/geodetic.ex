defmodule EphCore.Geometry.Geodetic do
  @moduledoc """
  WGS84 geodetic conversions.
  """

  import AstroUtils.Angle, only: [deg_to_rad: 1]

  @a_km 6_378.137
  @f 1.0 / 298.257223563
  @e_sq @f * (2.0 - @f)

  @spec to_ecef_km(float(), float(), float()) :: {float(), float(), float()}
  def to_ecef_km(lat_deg, lon_deg, height_m) do
    lat = deg_to_rad(lat_deg)
    lon = deg_to_rad(lon_deg)
    h_km = height_m / 1000.0

    sin_lat = :math.sin(lat)
    cos_lat = :math.cos(lat)
    cos_lon = :math.cos(lon)
    sin_lon = :math.sin(lon)

    n = @a_km / :math.sqrt(1.0 - @e_sq * sin_lat * sin_lat)

    x = (n + h_km) * cos_lat * cos_lon
    y = (n + h_km) * cos_lat * sin_lon
    z = (n * (1.0 - @e_sq) + h_km) * sin_lat

    {x, y, z}
  end

  @doc """
  Local east/north/up unit vectors in ECEF for a geodetic `lat`/`lon`.

  `up` is the **ellipsoid normal** (the geodetic vertical), not the geocentric
  radial — so the resulting horizon plane accounts for the WGS84 deflection of
  the vertical (≈0.1–0.2° at mid-latitudes), which a position-vector basis omits.
  """
  @spec enu_basis_ecef(float(), float()) ::
          %{
            east: {float(), float(), float()},
            north: {float(), float(), float()},
            up: {float(), float(), float()}
          }
  def enu_basis_ecef(lat_deg, lon_deg) do
    lat = deg_to_rad(lat_deg)
    lon = deg_to_rad(lon_deg)

    sin_lat = :math.sin(lat)
    cos_lat = :math.cos(lat)
    sin_lon = :math.sin(lon)
    cos_lon = :math.cos(lon)

    %{
      east: {-sin_lon, cos_lon, 0.0},
      north: {-sin_lat * cos_lon, -sin_lat * sin_lon, cos_lat},
      up: {cos_lat * cos_lon, cos_lat * sin_lon, sin_lat}
    }
  end
end
