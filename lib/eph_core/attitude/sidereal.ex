defmodule EphCore.Attitude.Sidereal do
  @moduledoc false

  alias EphCore.EarthOrientation.Sidereal, as: Impl

  defdelegate gmst_iau_2006(jd_ut1, jd_tt), to: Impl
  defdelegate gmst_iau_2006_seconds(jd_ut1, jd_tt), to: Impl
  defdelegate gast_iau_2006(jd_ut1, jd_tt), to: Impl
  defdelegate equation_of_equinoxes(jd_tt), to: Impl
  defdelegate gmst_to_lst(gmst_deg, lon_deg), to: Impl
  defdelegate lst_to_hours(lst_deg), to: Impl
  defdelegate julian_centuries_since_j2000(jd), to: Impl
  defdelegate seconds_to_degrees(seconds), to: Impl
  defdelegate normalize_angle(degrees), to: Impl
  defdelegate precession_matrix_iau2006(jd_tt), to: Impl
  defdelegate mean_obliquity_iau2006(jd_tt), to: Impl
  defdelegate mean_precession_matrix_iau2006(jd_tt), to: Impl
  defdelegate fundamental_arguments_iau2000(jd_tt), to: Impl
  defdelegate nutation_iau2000a(jd_tt), to: Impl
  defdelegate true_precession_matrix_iau2006(jd_tt), to: Impl
  defdelegate true_precession_matrix_iau2006(jd_tt, nutation), to: Impl
  defdelegate true_obliquity_iau2006(jd_tt), to: Impl
  defdelegate true_obliquity_iau2006(jd_tt, nutation), to: Impl
  defdelegate nutation_matrix_iau2006(jd_tt), to: Impl
  defdelegate nutation_in_obliquity(jd_tt), to: Impl
end
