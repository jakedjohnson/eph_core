defmodule EphCore.Geometry.Ecliptic do
  @moduledoc """
  Ecliptic coordinate transforms.
  """

  alias AstroUtils.{Angle, Matrix3}
  alias EphCore.EarthOrientation.Sidereal

  # IAU 2006 mean obliquity at J2000.0
  @j2000_obliquity_deg 23.4392911

  @doc """
  Rotate an ICRF vector into the J2000 ecliptic frame.
  """
  @spec icrf_to_j2000_ecliptic({float(), float(), float()}) :: {float(), float(), float()}
  def icrf_to_j2000_ecliptic({x, y, z}) do
    eps = @j2000_obliquity_deg * :math.pi() / 180.0
    cos_eps = :math.cos(eps)
    sin_eps = :math.sin(eps)

    x_ecl = x
    y_ecl = y * cos_eps + z * sin_eps
    z_ecl = -y * sin_eps + z * cos_eps

    {x_ecl, y_ecl, z_ecl}
  end

  @doc """
  Convert an ecliptic cartesian vector to longitude/latitude in degrees.
  """
  @spec ecliptic_lon_lat({float(), float(), float()}) :: {float(), float()}
  def ecliptic_lon_lat({x, y, z}) do
    lon = Angle.atan2_lon(y, x)
    r = :math.sqrt(x * x + y * y + z * z)
    lat = :math.asin(z / r) * 180.0 / :math.pi()

    {lon, lat}
  end

  @doc """
  Compute J2000 ecliptic longitude/latitude from an ICRF vector.
  """
  @spec icrf_to_j2000_lon_lat({float(), float(), float()}) :: {float(), float()}
  def icrf_to_j2000_lon_lat(vector) do
    vector
    |> icrf_to_j2000_ecliptic()
    |> ecliptic_lon_lat()
  end

  @doc """
  Rotate an ICRF vector into the mean-of-date ecliptic frame.
  """
  @spec icrf_to_mean_ecliptic_of_date({float(), float(), float()}, float()) ::
          {float(), float(), float()}
  def icrf_to_mean_ecliptic_of_date(vector, jd_tt) do
    mean_precession = Sidereal.mean_precession_matrix_iau2006(jd_tt)
    mean_obliquity_rad = Sidereal.mean_obliquity_iau2006(jd_tt) * :math.pi() / 180.0

    vector
    |> then(&Matrix3.multiply_vector(mean_precession, &1))
    |> then(&Matrix3.multiply_vector(Matrix3.rot_x(-mean_obliquity_rad), &1))
  end

  @doc """
  Rotate an ICRF vector into the true-of-date ecliptic frame.
  """
  @spec icrf_to_true_ecliptic_of_date({float(), float(), float()}, float()) ::
          {float(), float(), float()}
  def icrf_to_true_ecliptic_of_date(vector, jd_tt) do
    nutation = Sidereal.nutation_iau2000a(jd_tt)
    icrf_to_true_ecliptic_of_date(vector, jd_tt, nutation)
  end

  @doc false
  def icrf_to_true_ecliptic_of_date(vector, jd_tt, nutation)
      when is_tuple(nutation) do
    true_precession = Sidereal.true_precession_matrix_iau2006(jd_tt, nutation)
    true_obliquity_rad = Sidereal.true_obliquity_iau2006(jd_tt, nutation) * :math.pi() / 180.0

    vector
    |> then(&Matrix3.multiply_vector(true_precession, &1))
    |> then(&Matrix3.multiply_vector(Matrix3.rot_x(-true_obliquity_rad), &1))
  end

  @doc """
  Compute mean-of-date ecliptic longitude/latitude from an ICRF vector.
  """
  @spec icrf_to_mean_lon_lat({float(), float(), float()}, float()) :: {float(), float()}
  def icrf_to_mean_lon_lat(vector, jd_tt) do
    vector
    |> icrf_to_mean_ecliptic_of_date(jd_tt)
    |> ecliptic_lon_lat()
  end

  @doc """
  Compute true-of-date ecliptic longitude/latitude from an ICRF vector.
  """
  @spec icrf_to_true_lon_lat({float(), float(), float()}, float()) :: {float(), float()}
  def icrf_to_true_lon_lat(vector, jd_tt) do
    nutation = Sidereal.nutation_iau2000a(jd_tt)
    icrf_to_true_lon_lat(vector, jd_tt, nutation)
  end

  @doc false
  def icrf_to_true_lon_lat(vector, jd_tt, nutation) when is_tuple(nutation) do
    vector
    |> icrf_to_true_ecliptic_of_date(jd_tt, nutation)
    |> ecliptic_lon_lat()
  end
end
