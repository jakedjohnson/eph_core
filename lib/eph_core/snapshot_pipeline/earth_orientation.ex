defmodule EphCore.SnapshotPipeline.EarthOrientation do
  @moduledoc """
  Stage 02: EARTH_ORIENTATION — compute Earth's rotation at the epoch.

  Produces sidereal time and an ECEF ↔ inertial rotation matrix with provenance.
  """

  alias EphCore.EarthOrientation.Sidereal
  alias AstroUtils.Matrix3
  alias EphCore.SnapshotPipeline.{AstronomicalTime, Snapshot}
  alias EphCore.Telemetry

  defstruct [
    :gmst_degrees,
    :gast_degrees,
    :rotation_matrix,
    :model,
    :precession_nutation_applied,
    :polar_motion_applied
  ]

  @type t :: %__MODULE__{
          gmst_degrees: float(),
          gast_degrees: float() | nil,
          rotation_matrix: Matrix3.t(),
          model: atom(),
          precession_nutation_applied: boolean(),
          polar_motion_applied: boolean()
        }

  @spec resolve(term()) :: term()
  def resolve(%Snapshot{intent: intent, astronomical_time: %AstronomicalTime{} = time} = snapshot) do
    start = System.monotonic_time(:microsecond)
    Telemetry.stage_start(:earth_orientation)

    earth_orientation = from_intent(intent, time)

    duration = System.monotonic_time(:microsecond) - start
    Telemetry.stage_stop(:earth_orientation, duration)

    %{snapshot | earth_orientation: earth_orientation}
  end

  defp from_intent(%{models: models, corrections: corrections}, %AstronomicalTime{} = time) do
    model = Map.get(models, :earth_orientation, :gmst)
    precession_nutation_applied = Map.get(corrections, :precession_nutation, false)

    gmst = Sidereal.gmst_iau_2006(time.jd_ut1, time.jd_tt)

    {gast, angle_degrees} =
      case model do
        :gast ->
          gast_value = Sidereal.gast_iau_2006(time.jd_ut1, time.jd_tt)
          {gast_value, gast_value}

        _ ->
          {nil, gmst}
      end

    rotation_matrix =
      angle_degrees
      |> AstroUtils.Angle.deg_to_rad()
      |> build_rotation_matrix(time.jd_tt, precession_nutation_applied)

    %__MODULE__{
      gmst_degrees: gmst,
      gast_degrees: gast,
      rotation_matrix: rotation_matrix,
      model: model,
      precession_nutation_applied: precession_nutation_applied,
      polar_motion_applied: false
    }
  end

  defp build_rotation_matrix(angle_rad, jd_tt, true) do
    precession_nutation = Sidereal.true_precession_matrix_iau2006(jd_tt)
    # ECEF to GCRS: rotate by +GMST/GAST (Earth's rotation angle)
    Matrix3.multiply(precession_nutation, Matrix3.rot_z(angle_rad))
  end

  defp build_rotation_matrix(angle_rad, _jd_tt, false) do
    # ECEF to GCRS: rotate by +GMST/GAST (Earth's rotation angle)
    Matrix3.rot_z(angle_rad)
  end
end
