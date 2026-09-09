defmodule EphCore.AstronomicalTime.InternationalAtomicTime do
  @moduledoc """
  TAI is the primary international atomic time scale.
  It's a continuous time scale that's perfectly uniform (unlike UT1 which wobbles with Earth rotation).
  TAI ticks at the same rate as proper atomic time standards, but it's offset from UTC by accumulated leap seconds.

  In short:
    * **TAI = Atomic clock time.** It's the "clean" atomic time scale without leap-second corrections.
    * It runs ahead of UTC by the total number of leap seconds inserted since 1972.
    * It provides a uniform timescale for scientific calculations.
    * TAI is the foundation for Terrestrial Time (TT), which is used in astronomical ephemerides.

  ## Relationship to UTC

  TAI = UTC + (TAI-UTC leap offset)

  The leap offset is the total accumulated leap seconds since the TAI/UTC epoch (1972).
  This offset grows over time as leap seconds are inserted to keep UTC synchronized with Earth's rotation.

  ## Current Implementation

  This module provides `from_utc/1` which converts UTC DateTime to TAI by:
  1. Looking up the appropriate leap-second offset from the `LeapSeconds` table
  2. Adding that offset (in microseconds) to the input UTC time

  **Usage in the application:**
  - Used by `TerrestrialTime.from_utc/1` to compute TT = TAI + 32.184 seconds
  - Handles dates from before 1972 (0 leap seconds) through current dates
  - Maintains microsecond precision throughout the conversion
  """

  alias EphCore.AstronomicalTime.Tables.LeapSeconds

  def from_utc(utc_datetime) do
    leap_microseconds = LeapSeconds.offset_at(utc_datetime)
    DateTime.add(utc_datetime, leap_microseconds, :microsecond)
  end
end
