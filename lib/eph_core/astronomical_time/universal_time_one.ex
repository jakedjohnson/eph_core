defmodule EphCore.AstronomicalTime.UniversalTimeOne do
  @moduledoc """
  UT1 is basically *Earth’s actual rotation time*.
  Think of it as “astronomical clock time,” determined by how far the Earth has spun relative to the stars.
  It’s the modern, high-precision descendant of old Greenwich Mean Time (GMT),
  except UT1 wobbles slightly because Earth’s rotation isn’t perfectly steady — tides, earthquakes,
  and atmosphere drag the planet around just enough to make it drift by milliseconds each day.

  In short:
    * **UT1 = “True” Earth-rotation time.**
    * It defines what the angle of the Earth is right now (used for sidereal time, Local Apparent Sidereal Time, etc.).
    * It’s *not uniform* — it speeds up and slows down unpredictably.
    * The difference between atomic time and UT1 is tracked as **ΔUT1**, which is kept within ±0.9 s by adding or removing **leap seconds** to UTC.
  """

  alias EphCore.AstronomicalTime.Tables.EarthOrientationParameters

  def delta_for_mjd_utc(mjd_utc) do
    EarthOrientationParameters.ut1_minus_utc_seconds(mjd_utc)
  end

  @doc """
  Converts a Modified Julian Day to Universal Time 1.

  MJD(UT1) = MJD(UTC) + (UT1-UTC)/86400

  Inputs are MODIFIED Julian days, microsecond precise: `48337.80972222239`
  """
  def apply_delta(jd_utc, ms_delta_from_mjd_utc) do
    delta_days = ms_delta_from_mjd_utc / 86_400
    jd_utc + delta_days
  end
end
