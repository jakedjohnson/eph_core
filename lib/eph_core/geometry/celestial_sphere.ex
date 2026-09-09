defmodule EphCore.Geometry.CelestialSphere do
  @moduledoc """
  Helpers for computing celestial poles and great-circle ring samples.
  """

  alias AstroUtils.{Matrix3, Vector}
  alias EphCore.EarthOrientation.Sidereal
  alias EphCore.Geometry.Horizontal
  alias EphCore.SnapshotPipeline.Observation

  @j2000_obliquity_deg 23.4392911
  @default_ring_samples 24

  @spec geometry_payload(Observation.t()) :: %{
          ring_samples: integer(),
          poles: %{equatorial: map(), ecliptic: map()},
          rings: %{equatorial: list(map()), ecliptic: list(map())}
        }
  def geometry_payload(%Observation{
        intent: intent,
        epoch: epoch,
        observer_position: %{local_basis: local_basis}
      }) do
    ring_samples = ring_samples_from_intent(intent)
    equatorial_pole = equatorial_pole_icrf(intent.models.ecliptic_frame, epoch.jd_tt)
    ecliptic_pole = ecliptic_pole_icrf(intent.models.ecliptic_frame, epoch.jd_tt)

    poles = %{
      equatorial: alt_az_map(equatorial_pole, local_basis),
      ecliptic: alt_az_map(ecliptic_pole, local_basis)
    }

    rings = %{
      equatorial: ring_alt_az_samples(equatorial_pole, local_basis, ring_samples),
      ecliptic: ring_alt_az_samples(ecliptic_pole, local_basis, ring_samples)
    }

    %{ring_samples: ring_samples, poles: poles, rings: rings}
  end

  defp ring_samples_from_intent(%{geometry: %{ring_samples: ring_samples}})
       when is_integer(ring_samples) and ring_samples >= 0 do
    ring_samples
  end

  defp ring_samples_from_intent(_intent), do: @default_ring_samples

  defp alt_az_map(direction, local_basis) do
    {altitude_deg, azimuth_deg} = Horizontal.alt_az_from_direction(direction, local_basis)
    %{altitude_deg: altitude_deg, azimuth_deg: azimuth_deg}
  end

  defp ring_alt_az_samples(_pole, _local_basis, ring_samples) when ring_samples == 0 do
    []
  end

  defp ring_alt_az_samples(pole, local_basis, ring_samples) do
    pole_unit = Vector.normalize(pole)
    {u_axis, v_axis} = orthonormal_basis(pole_unit)
    step = 2.0 * :math.pi() / ring_samples

    Enum.map(0..(ring_samples - 1), fn i ->
      theta = step * i

      direction =
        u_axis
        |> Vector.scale(:math.cos(theta))
        |> Vector.add(Vector.scale(v_axis, :math.sin(theta)))

      alt_az_map(direction, local_basis)
    end)
  end

  defp orthonormal_basis(pole_unit) do
    {_, _, z} = pole_unit
    reference = if abs(z) < 0.9, do: {0.0, 0.0, 1.0}, else: {1.0, 0.0, 0.0}
    u_axis = pole_unit |> Vector.cross(reference) |> Vector.normalize()
    v_axis = Vector.cross(pole_unit, u_axis)
    {u_axis, v_axis}
  end

  defp equatorial_pole_icrf(:j2000, _jd_tt), do: {0.0, 0.0, 1.0}

  defp equatorial_pole_icrf(:mean_of_date, jd_tt) do
    jd_tt
    |> Sidereal.mean_precession_matrix_iau2006()
    |> Matrix3.transpose()
    |> Matrix3.multiply_vector({0.0, 0.0, 1.0})
  end

  defp equatorial_pole_icrf(:true_of_date, jd_tt) do
    jd_tt
    |> Sidereal.true_precession_matrix_iau2006()
    |> Matrix3.transpose()
    |> Matrix3.multiply_vector({0.0, 0.0, 1.0})
  end

  defp equatorial_pole_icrf(_frame, _jd_tt), do: {0.0, 0.0, 1.0}

  defp ecliptic_pole_icrf(:j2000, _jd_tt) do
    eps_rad = @j2000_obliquity_deg * :math.pi() / 180.0
    Matrix3.multiply_vector(Matrix3.rot_x(eps_rad), {0.0, 0.0, 1.0})
  end

  defp ecliptic_pole_icrf(:mean_of_date, jd_tt) do
    eps_rad = Sidereal.mean_obliquity_iau2006(jd_tt) * :math.pi() / 180.0
    pole = Matrix3.multiply_vector(Matrix3.rot_x(eps_rad), {0.0, 0.0, 1.0})

    jd_tt
    |> Sidereal.mean_precession_matrix_iau2006()
    |> Matrix3.transpose()
    |> Matrix3.multiply_vector(pole)
  end

  defp ecliptic_pole_icrf(:true_of_date, jd_tt) do
    eps_rad = Sidereal.true_obliquity_iau2006(jd_tt) * :math.pi() / 180.0
    pole = Matrix3.multiply_vector(Matrix3.rot_x(eps_rad), {0.0, 0.0, 1.0})

    jd_tt
    |> Sidereal.true_precession_matrix_iau2006()
    |> Matrix3.transpose()
    |> Matrix3.multiply_vector(pole)
  end

  defp ecliptic_pole_icrf(_frame, _jd_tt) do
    eps_rad = @j2000_obliquity_deg * :math.pi() / 180.0
    Matrix3.multiply_vector(Matrix3.rot_x(eps_rad), {0.0, 0.0, 1.0})
  end
end
