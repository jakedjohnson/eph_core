defmodule EphCore.SnapshotPipeline.ObserverPosition do
  @moduledoc """
  Stage 03: OBSERVER_POSITION — place the observer in inertial space.
  """

  alias EphCore.EarthOrientation.Sidereal
  alias AstroUtils.{Matrix3, Vector}
  alias EphCore.Geometry.{Geodetic, Horizontal}
  alias EphCore.SnapshotPipeline.{EarthOrientation, Snapshot}
  alias EphCore.Telemetry

  defstruct [
    :geodetic,
    :ecef_position_km,
    :inertial_position_km,
    :local_basis,
    :last_deg,
    :lmst_deg,
    :ellipsoid,
    :frame
  ]

  @type t :: %__MODULE__{
          geodetic: %{lat_deg: float(), lon_deg: float(), height_m: float()},
          ecef_position_km: {float(), float(), float()},
          inertial_position_km: {float(), float(), float()},
          local_basis: %{east: Vector.t(), north: Vector.t(), up: Vector.t()},
          last_deg: float(),
          lmst_deg: float(),
          ellipsoid: atom(),
          frame: atom()
        }

  @spec resolve(term()) :: term()
  def resolve(
        %Snapshot{
          intent: %{observer: %{lat_deg: lat_deg, lon_deg: lon_deg, height_m: height_m}},
          earth_orientation: %EarthOrientation{} = earth_orientation
        } = snapshot
      ) do
    start = System.monotonic_time(:microsecond)
    Telemetry.stage_start(:observer_position)

    observer_position = from_intent(lat_deg, lon_deg, height_m, earth_orientation)

    duration = System.monotonic_time(:microsecond) - start
    Telemetry.stage_stop(:observer_position, duration)

    %{snapshot | observer_position: observer_position}
  end

  defp from_intent(lat_deg, lon_deg, height_m, %EarthOrientation{} = earth_orientation) do
    ecef_position_km = Geodetic.to_ecef_km(lat_deg, lon_deg, height_m)

    inertial_position_km =
      Matrix3.multiply_vector(earth_orientation.rotation_matrix, ecef_position_km)

    {last_deg, lmst_deg} = compute_sidereal(earth_orientation, lon_deg)
    local_basis = Horizontal.local_basis(lat_deg, lon_deg, earth_orientation.rotation_matrix)

    %__MODULE__{
      geodetic: %{lat_deg: lat_deg, lon_deg: lon_deg, height_m: height_m},
      ecef_position_km: ecef_position_km,
      inertial_position_km: inertial_position_km,
      local_basis: local_basis,
      last_deg: last_deg,
      lmst_deg: lmst_deg,
      ellipsoid: :wgs84,
      frame: :icrf
    }
  end

  defp compute_sidereal(%EarthOrientation{} = earth_orientation, lon_deg) do
    gmst = earth_orientation.gmst_degrees
    gast = earth_orientation.gast_degrees || gmst

    lmst = Sidereal.normalize_angle(gmst + lon_deg)
    last = Sidereal.normalize_angle(gast + lon_deg)

    {last, lmst}
  end
end
