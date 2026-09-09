defmodule EphCore.SnapshotPipeline.AstronomicalTime do
  @moduledoc """
  Stage 01: ASTRONOMICAL_TIME — establish the moment in astronomical time.

  Appends time scale conversions to the snapshot for downstream stages.
  """

  alias EphCore.EarthOrientation.Sidereal
  alias EphCore.SnapshotPipeline.Snapshot
  alias EphCore.Telemetry
  alias EphCore.AstronomicalTime.{JulianDay, TerrestrialTime, UniversalTimeOne}

  @seconds_per_day 86_400.0

  defstruct [:jd_utc, :jd_ut1, :jd_tt, :delta_t_seconds, :delta_t_source]

  @type t :: %__MODULE__{
          jd_utc: float(),
          jd_ut1: float(),
          jd_tt: float(),
          delta_t_seconds: float(),
          delta_t_source: atom()
        }

  @spec resolve(term()) :: term()
  def resolve(%Snapshot{intent: intent} = snapshot) do
    start = System.monotonic_time(:microsecond)
    Telemetry.stage_start(:astronomical_time)

    astronomical_time = from_intent(intent)

    duration = System.monotonic_time(:microsecond) - start
    Telemetry.stage_stop(:astronomical_time, duration)

    snapshot
    |> Map.put(:astronomical_time, astronomical_time)
    |> attach_true_of_date_nutation()
  end

  defp attach_true_of_date_nutation(
         %Snapshot{
           intent: %{models: %{ecliptic_frame: :true_of_date}},
           astronomical_time: %{jd_tt: jd_tt}
         } = snapshot
       ) do
    %{snapshot | true_of_date_nutation: Sidereal.nutation_iau2000a(jd_tt)}
  end

  defp attach_true_of_date_nutation(snapshot), do: snapshot

  defp from_intent(%{utc: utc, models: models}) do
    jd_utc = JulianDay.from_datetime(utc)
    mjd_utc = JulianDay.modified_julian_day(jd_utc)

    {jd_tt, delta_t_source} = jd_tt_for(utc, jd_utc, models)
    jd_ut1 = jd_ut1_for(jd_utc, mjd_utc, models)
    delta_t_seconds = (jd_tt - jd_ut1) * @seconds_per_day

    %__MODULE__{
      jd_utc: jd_utc,
      jd_ut1: jd_ut1,
      jd_tt: jd_tt,
      delta_t_seconds: delta_t_seconds,
      delta_t_source: delta_t_source
    }
  end

  defp jd_tt_for(utc, _jd_utc, %{delta_t: :iers}) do
    tt = TerrestrialTime.from_utc(utc)
    {JulianDay.from_datetime(tt), :iers}
  end

  defp jd_tt_for(_utc, jd_utc, _models) do
    delta_t = 69.184
    {jd_utc + delta_t / @seconds_per_day, :approximate}
  end

  defp jd_ut1_for(jd_utc, mjd_utc, %{delta_t: :iers}) do
    ut1_utc = UniversalTimeOne.delta_for_mjd_utc(mjd_utc)
    UniversalTimeOne.apply_delta(jd_utc, ut1_utc)
  end

  defp jd_ut1_for(jd_utc, _mjd_utc, _models), do: jd_utc
end
