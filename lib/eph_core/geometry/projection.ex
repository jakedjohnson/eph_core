defmodule EphCore.Geometry.Projection do
  @moduledoc """
  Projection helpers between equatorial and ecliptic coordinates.
  """

  alias AstroUtils.Angle

  @doc """
  Project equatorial RA (Dec=0) to ecliptic longitude.
  """
  @spec equator_ra_to_ecliptic_lon(float(), float()) :: float()
  def equator_ra_to_ecliptic_lon(ra_deg, obliquity_deg)
      when is_number(ra_deg) and is_number(obliquity_deg) do
    ra_rad = ra_deg * :math.pi() / 180.0
    eps_rad = obliquity_deg * :math.pi() / 180.0

    Angle.atan2_lon(:math.sin(ra_rad), :math.cos(ra_rad) * :math.cos(eps_rad))
  end
end
