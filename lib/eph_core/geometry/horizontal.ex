defmodule EphCore.Geometry.Horizontal do
  @moduledoc """
  Helpers for converting direction vectors into local horizon coordinates.
  """

  alias AstroUtils.{Angle, Matrix3, Vector}
  alias EphCore.Geometry.Geodetic

  @type local_basis :: %{east: Vector.t(), north: Vector.t(), up: Vector.t()}

  @doc """
  Build the local east/north/up basis in the inertial (GCRS/ICRF) frame from a
  geodetic `lat`/`lon` and the ECEF→inertial rotation matrix.

  `up` is the **ellipsoid normal** (the geodetic vertical) rather than the
  geocentric radial, so the horizon plane reflects the WGS84 deflection of the
  vertical (≈0.1–0.2° at mid-latitudes). Using the radial instead tilts the whole
  alt/az frame and produces a systematic ~1–3 min rise/set/transit error.

  Shared by `EphCore.SnapshotPipeline.ObserverPosition` and the almanac
  apparent-place pass so both derive alt/az from one definition.
  """
  @spec local_basis(float(), float(), Matrix3.t()) :: local_basis()
  def local_basis(lat_deg, lon_deg, ecef_to_inertial) do
    %{east: east_ecef, north: north_ecef, up: up_ecef} =
      Geodetic.enu_basis_ecef(lat_deg, lon_deg)

    %{
      east: Matrix3.multiply_vector(ecef_to_inertial, east_ecef),
      north: Matrix3.multiply_vector(ecef_to_inertial, north_ecef),
      up: Matrix3.multiply_vector(ecef_to_inertial, up_ecef)
    }
  end

  @spec alt_az_from_direction(Vector.t(), local_basis()) ::
          {float(), float()}
  def alt_az_from_direction(direction, local_basis) do
    east_component = Vector.dot(direction, local_basis.east)
    north_component = Vector.dot(direction, local_basis.north)
    up_component = Vector.dot(direction, local_basis.up)

    altitude_rad =
      :math.atan2(
        up_component,
        :math.sqrt(east_component * east_component + north_component * north_component)
      )

    altitude_deg = Angle.rad_to_deg(altitude_rad)
    azimuth_deg = Angle.atan2_lon(east_component, north_component)

    {altitude_deg, azimuth_deg}
  end
end
