defmodule EphCore.AstronomicalTime.JulianDay do
  @moduledoc """
  Julian Date (JD) conversion functions for astronomical time calculations.

  The Julian Date is a continuous count of days since noon Universal Time on
  January 1, 4713 BC (proleptic Julian calendar). It is widely used in astronomy
  because it avoids the complexities of calendars and provides a simple linear
  time scale.

  ## When to Use

  - Converting between calendar dates and astronomical time scales
  - Calculating time intervals between astronomical events
  - Interfacing with astronomical algorithms and ephemeris data

  ## Precision

  `from_datetime/1` is microsecond-precise, which is sufficient for the
  ephemeris and time-scale conversions in this library.

  ## Examples

      # J2000.0 epoch
      JulianDay.from_datetime(~U[2000-01-01 12:00:00.000000Z])
      #=> 2451545.0
  """

  @doc """
  Convert a DateTime to Julian Date (JD).

  Returns the number of days (including fractional days) since noon on
  January 1, 4713 BC. This implementation is microsecond-precise and uses
  a simplified algorithm suitable for most astronomical calculations.

  ## Examples

      iex> dt = ~U[2000-01-01 12:00:00.000000Z]
      iex> JulianDay.from_datetime(dt)
      2451545.0

      iex> dt = ~U[2024-06-15 18:30:00.000000Z]
      iex> JulianDay.from_datetime(dt)
      2460478.270833333
  """
  @spec from_datetime(DateTime.t()) :: float()
  def from_datetime(%DateTime{
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute,
        second: second,
        microsecond: {microsecond, _}
      }) do
    a = div(14 - month, 12)
    y = year + 4800 - a
    m = month + 12 * a - 3

    julian_day_num =
      day + div(153 * m + 2, 5) + 365 * y + div(y, 4) - div(y, 100) + div(y, 400) - 32_045

    # Calculate the fraction of the day from the time components
    day_fraction = hour / 24 + minute / 1440 + second / 86_400 + microsecond / 86_400_000_000

    # Add the fraction and subtract 0.5 because JD starts at noon
    julian_day_num - 0.5 + day_fraction
  end

  @doc """
  Modified Julian Day (MJD) counts days since midnight on November 17, 1858

  accomplishes two things:
    * Moves the epoch from noon to midnight.
    * Puts modern dates in the ~50 000 range instead of 2.4 million.
  """
  @spec modified_julian_day(float()) :: float()
  def modified_julian_day(julian_day) do
    julian_day - 2_400_000.5
  end
end
