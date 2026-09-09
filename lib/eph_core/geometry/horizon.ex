defmodule EphCore.Geometry.Horizon do
  @moduledoc """
  Horizon-based geometry helpers (east horizon ecliptic longitude / meridian ecliptic longitude).
  """

  alias AstroUtils.Angle
  alias EphCore.EarthOrientation.Sidereal

  @type east_horizon_ecliptic_result :: %{
          east_horizon_ecliptic_longitude: float(),
          lst: float(),
          obliquity: float(),
          obliquity_model: atom(),
          sidereal_time_type: atom()
        }

  @doc """
  Compute the ecliptic longitude at the eastern horizon.
  """
  @spec ecliptic_lon_at_east_horizon(float(), float(), float(), keyword()) ::
          east_horizon_ecliptic_result()
  def ecliptic_lon_at_east_horizon(jd_tt, lat_deg, lon_deg, opts \\ [])
      when is_number(jd_tt) and is_number(lat_deg) and is_number(lon_deg) do
    sidereal_time_type = Keyword.get(opts, :sidereal_time_type, :apparent)
    obliquity_model = Keyword.get(opts, :obliquity_model, :true_of_date)

    lst = local_sidereal_time(jd_tt, lon_deg, sidereal_time_type, opts)
    obliquity = obliquity_for(jd_tt, obliquity_model)

    east_horizon_ecliptic_lon = east_horizon_ecliptic_formula(lst, lat_deg, obliquity)

    %{
      east_horizon_ecliptic_longitude: east_horizon_ecliptic_lon,
      lst: lst,
      obliquity: obliquity,
      obliquity_model: obliquity_model,
      sidereal_time_type: sidereal_time_type
    }
  end

  @doc """
  Compute the ecliptic longitude on the local meridian.
  """
  @spec ecliptic_lon_on_meridian(float(), float(), keyword()) :: %{
          meridian_ecliptic_longitude: float(),
          lst: float(),
          obliquity: float(),
          obliquity_model: atom(),
          sidereal_time_type: atom()
        }
  def ecliptic_lon_on_meridian(jd_tt, lon_deg, opts \\ [])
      when is_number(jd_tt) and is_number(lon_deg) do
    sidereal_time_type = Keyword.get(opts, :sidereal_time_type, :apparent)
    obliquity_model = Keyword.get(opts, :obliquity_model, :true_of_date)

    lst = local_sidereal_time(jd_tt, lon_deg, sidereal_time_type, opts)
    obliquity = obliquity_for(jd_tt, obliquity_model)

    lst_rad = lst * :math.pi() / 180.0
    eps_rad = obliquity * :math.pi() / 180.0

    mc_lon =
      Angle.atan2_lon(:math.sin(lst_rad), :math.cos(lst_rad) * :math.cos(eps_rad))

    %{
      meridian_ecliptic_longitude: mc_lon,
      lst: lst,
      obliquity: obliquity,
      obliquity_model: obliquity_model,
      sidereal_time_type: sidereal_time_type
    }
  end

  defp local_sidereal_time(jd_tt, lon_deg, :mean, opts) do
    jd_ut1 = Keyword.get(opts, :jd_ut1, jd_tt)
    gmst = Sidereal.gmst_iau_2006(jd_ut1, jd_tt)
    Angle.normalize_360(gmst + lon_deg)
  end

  defp local_sidereal_time(jd_tt, lon_deg, _type, opts) do
    jd_ut1 = Keyword.get(opts, :jd_ut1, jd_tt)
    gast = Sidereal.gast_iau_2006(jd_ut1, jd_tt)
    Angle.normalize_360(gast + lon_deg)
  end

  defp obliquity_for(_jd_tt, :j2000), do: 23.4392911
  defp obliquity_for(jd_tt, :true_of_date), do: Sidereal.true_obliquity_iau2006(jd_tt)
  defp obliquity_for(jd_tt, _), do: Sidereal.mean_obliquity_iau2006(jd_tt)

  # Standard east horizon ecliptic longitude formula from Meeus "Astronomical Algorithms":
  #   tan(λ_eh) = -cos(RAMC) / (sin(RAMC)·cos(ε) + tan(φ)·sin(ε))
  #
  # Rearranged for atan2 (y, x) form:
  #   y = cos(RAMC)
  #   x = -(sin(ε)·tan(φ) + cos(ε)·sin(RAMC))
  #
  # References:
  #   - Meeus, Jean. "Astronomical Algorithms" 2nd ed., Chapter 13
  #   - Swiss Ephemeris documentation
  defp east_horizon_ecliptic_formula(lst_deg, lat_deg, obliquity_deg) do
    lst_rad = lst_deg * :math.pi() / 180.0
    lat_rad = lat_deg * :math.pi() / 180.0
    eps_rad = obliquity_deg * :math.pi() / 180.0

    Angle.atan2_lon(
      :math.cos(lst_rad),
      -(:math.sin(eps_rad) * :math.tan(lat_rad) + :math.cos(eps_rad) * :math.sin(lst_rad))
    )
  end
end
