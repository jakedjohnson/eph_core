defmodule EphCore.Stars.Position do
  @moduledoc """
  Fixed-star position computation from Hipparcos catalog records.

  Applies proper motion, converts to ecliptic and equatorial-of-date coordinates,
  and optionally projects to local altitude/azimuth.

  For large N, prefer `compute_many/3` — it builds the per-epoch precession/
  nutation matrix (and observer local basis) once and reuses them across stars.
  """

  alias AstroUtils.{Angle, Matrix3, Vector}
  alias EphCore.EarthOrientation.Sidereal
  alias EphCore.Geometry.{Ecliptic, Horizontal}
  alias EphCore.Stars.Catalog

  @j1991_25_jd 2_448_349.0625
  @mas_per_degree 3_600_000.0

  @type star_record :: Catalog.star_record()

  @type observer :: %{lat_deg: float(), lon_deg: float(), height_m: float()}

  @type result :: %{
          ecliptic_lon_deg: float(),
          ecliptic_lat_deg: float(),
          ra_deg: float(),
          dec_deg: float(),
          altitude_deg: float() | nil,
          azimuth_deg: float() | nil,
          magnitude: float(),
          name: String.t() | nil,
          hip: integer()
        }

  @doc """
  Computes the full sky position of a catalog star at the given Julian Date (TT).

  ## Options

    * `:observer` — `%{lat_deg:, lon_deg:, height_m:}` for alt/az (optional)
    * `:lst_deg` — local sidereal time in degrees, required with `:observer` for alt/az

  """
  @spec compute(star_record(), float(), keyword()) :: result()
  def compute(star, jd_tt, opts \\ []) when is_map(star) and is_number(jd_tt) do
    icrf_vector = star |> apply_proper_motion(jd_tt) |> unit_vector_from_ra_dec()

    {ecliptic_lon_deg, ecliptic_lat_deg} = Ecliptic.icrf_to_true_lon_lat(icrf_vector, jd_tt)

    precessed_vector =
      jd_tt
      |> Sidereal.true_precession_matrix_iau2006()
      |> Matrix3.multiply_vector(icrf_vector)

    {ra_deg, dec_deg} = ra_dec_from_vector(precessed_vector)

    {altitude_deg, azimuth_deg} =
      alt_az(icrf_vector, jd_tt, opts)

    %{
      ecliptic_lon_deg: ecliptic_lon_deg,
      ecliptic_lat_deg: ecliptic_lat_deg,
      ra_deg: ra_deg,
      dec_deg: dec_deg,
      altitude_deg: altitude_deg,
      azimuth_deg: azimuth_deg,
      magnitude: star.magnitude,
      name: star.name,
      hip: star.hip
    }
  end

  @doc """
  Computes positions for many catalog stars at one epoch.

  Shares the IAU 2006/2000A true-of-date precession/nutation matrix (and, when
  alt/az is requested, the observer local basis) across the whole list — the
  honest N-star path. `compute/3` is unchanged for single-star callers.

  ## Options

    * `:observer` / `:lst_deg` — same as `compute/3`
    * `:parallel` — when `true`, process stars in chunks via `Task.async_stream`
      (default `false`). Chunk count defaults to `schedulers_online * 4`.
    * `:chunk_count` — override the number of parallel chunks

  """
  @spec compute_many([star_record()], float(), keyword()) :: [result()]
  def compute_many(stars, jd_tt, opts \\ []) when is_list(stars) and is_number(jd_tt) do
    nutation = Sidereal.nutation_iau2000a(jd_tt)
    precession = Sidereal.true_precession_matrix_iau2006(jd_tt, nutation)

    local_basis =
      case {Keyword.get(opts, :observer), Keyword.get(opts, :lst_deg)} do
        {%{lat_deg: lat_deg}, lst_deg} when is_number(lst_deg) ->
          local_basis_from_lat_lst(lat_deg, lst_deg)

        _ ->
          nil
      end

    ctx = %{
      jd_tt: jd_tt,
      nutation: nutation,
      precession: precession,
      local_basis: local_basis
    }

    if Keyword.get(opts, :parallel, false) do
      compute_many_parallel(stars, ctx, opts)
    else
      Enum.map(stars, &compute_one(&1, ctx))
    end
  end

  defp compute_many_parallel(stars, ctx, opts) do
    n = length(stars)
    schedulers = System.schedulers_online()
    chunk_count = Keyword.get(opts, :chunk_count, max(schedulers * 4, 1))
    chunk_size = max(div(n + chunk_count - 1, chunk_count), 1)

    stars
    |> Enum.chunk_every(chunk_size)
    |> Task.async_stream(
      fn chunk -> Enum.map(chunk, &compute_one(&1, ctx)) end,
      max_concurrency: schedulers,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.flat_map(fn {:ok, results} -> results end)
  end

  defp compute_one(star, %{
         jd_tt: jd_tt,
         nutation: nutation,
         precession: precession,
         local_basis: local_basis
       }) do
    icrf_vector = star |> apply_proper_motion(jd_tt) |> unit_vector_from_ra_dec()

    {ecliptic_lon_deg, ecliptic_lat_deg} =
      Ecliptic.icrf_to_true_lon_lat(icrf_vector, jd_tt, nutation)

    precessed_vector = Matrix3.multiply_vector(precession, icrf_vector)
    {ra_deg, dec_deg} = ra_dec_from_vector(precessed_vector)

    {altitude_deg, azimuth_deg} =
      case local_basis do
        nil ->
          {nil, nil}

        basis ->
          Horizontal.alt_az_from_direction(precessed_vector, basis)
      end

    %{
      ecliptic_lon_deg: ecliptic_lon_deg,
      ecliptic_lat_deg: ecliptic_lat_deg,
      ra_deg: ra_deg,
      dec_deg: dec_deg,
      altitude_deg: altitude_deg,
      azimuth_deg: azimuth_deg,
      magnitude: star.magnitude,
      name: star.name,
      hip: star.hip
    }
  end

  defp apply_proper_motion(star, jd_tt) do
    delta_t_years = (jd_tt - @j1991_25_jd) / 365.25
    dec_rad = Angle.deg_to_rad(star.dec_deg)
    cos_dec = :math.cos(dec_rad)

    delta_ra_deg =
      if cos_dec == 0.0 do
        0.0
      else
        star.pm_ra_mas_yr / cos_dec * delta_t_years / @mas_per_degree
      end

    delta_dec_deg = star.pm_dec_mas_yr * delta_t_years / @mas_per_degree

    %{
      star
      | ra_deg: star.ra_deg + delta_ra_deg,
        dec_deg: star.dec_deg + delta_dec_deg
    }
  end

  defp unit_vector_from_ra_dec(%{ra_deg: ra_deg, dec_deg: dec_deg}) do
    ra_rad = Angle.deg_to_rad(ra_deg)
    dec_rad = Angle.deg_to_rad(dec_deg)
    cos_dec = :math.cos(dec_rad)

    {cos_dec * :math.cos(ra_rad), cos_dec * :math.sin(ra_rad), :math.sin(dec_rad)}
  end

  defp ra_dec_from_vector({x, y, z}) do
    ra = Angle.atan2_lon(y, x)
    r = :math.sqrt(x * x + y * y + z * z)
    dec = :math.asin(z / r) * 180.0 / :math.pi()

    {ra, dec}
  end

  defp alt_az(icrf_vector, jd_tt, opts) do
    case {Keyword.get(opts, :observer), Keyword.get(opts, :lst_deg)} do
      {%{lat_deg: lat_deg}, lst_deg} when is_number(lst_deg) ->
        precessed_vector =
          jd_tt
          |> Sidereal.true_precession_matrix_iau2006()
          |> Matrix3.multiply_vector(icrf_vector)

        local_basis = local_basis_from_lat_lst(lat_deg, lst_deg)
        Horizontal.alt_az_from_direction(precessed_vector, local_basis)

      _ ->
        {nil, nil}
    end
  end

  defp local_basis_from_lat_lst(lat_deg, lst_deg) do
    lat_rad = Angle.deg_to_rad(lat_deg)
    lst_rad = Angle.deg_to_rad(lst_deg)

    cos_lat = :math.cos(lat_rad)
    sin_lat = :math.sin(lat_rad)
    cos_lst = :math.cos(lst_rad)
    sin_lst = :math.sin(lst_rad)

    up = {cos_lat * cos_lst, cos_lat * sin_lst, sin_lat}
    east = {-sin_lst, cos_lst, 0.0}
    north = {-sin_lat * cos_lst, -sin_lat * sin_lst, cos_lat}

    %{
      east: Vector.normalize(east),
      north: Vector.normalize(north),
      up: Vector.normalize(up)
    }
  end
end
