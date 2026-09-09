defmodule EphCore.AstronomicalTime.TerrestrialTime do
  @moduledoc """
  TT is a perfectly uniform time scale used for all astronomical calculations.
  It doesn’t care how Earth wobbles — it ticks smoothly according to atomic time standards.
  TT replaced “Ephemeris Time” (ET), which was the old theoretical time used for planetary motion.

  In short:
    * TT = Theoretical clock time used in equations.
    * It runs ahead of UTC by about 69s right now (because of accumulated leap seconds + a fixed historical offset).
    * It’s tied directly to TAI (International Atomic Time) by:
        * TT = TAI + 32.184 s.
    *  It’s what you use when computing ephemerides, orbital mechanics, or primary directions — anything needing uniform seconds.
  """

  alias EphCore.AstronomicalTime.InternationalAtomicTime
  alias EphCore.AstronomicalTime.Tables.LeapSeconds

  @doc """
    TT runs ahead of UTC by two parts:
    * The historical offset of 32.184 s (fixed).
    * The TAI–UTC offset (total leap seconds) valid at that epoch.

  "TAI" = International Atomic Time
  """
  @historical_offset_microseconds 32_184_000

  def from_utc(%DateTime{} = utc_datetime_microseconds) do
    tai = InternationalAtomicTime.from_utc(utc_datetime_microseconds)
    DateTime.add(tai, @historical_offset_microseconds, :microsecond)
  end

  @doc """
  Convert a TT DateTime back to UTC.

  Implementation notes:
  - TT = TAI + 32.184s
  - TAI = UTC + (TAI-UTC leap offset at UTC)
  - We resolve the leap offset with a short fixed-point iteration (max 2 passes).
  """
  def to_utc(%DateTime{} = tt_datetime) do
    tai = DateTime.add(tt_datetime, -@historical_offset_microseconds, :microsecond)

    # initial UTC guess: assume current leap offset at tai-as-utc
    utc_guess0 = tai
    leap0 = LeapSeconds.offset_at(utc_guess0)
    utc1 = DateTime.add(tai, -leap0, :microsecond)
    leap1 = LeapSeconds.offset_at(utc1)

    if leap1 == leap0 do
      utc1
    else
      # one more pass for stability across boundaries
      utc2 = DateTime.add(tai, -leap1, :microsecond)
      # final check (avoid infinite loops; leap table changes in steps)
      _leap2 = LeapSeconds.offset_at(utc2)
      utc2
    end
  end
end
