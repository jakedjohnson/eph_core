defmodule EphCore.Corrections.ApparentPlaceEclipticTest do
  use ExUnit.Case, async: false

  alias EphCore.Corrections.ApparentPlace

  @dt ~U[2026-05-20 10:27:49Z]
  @observer %{lat: 44.98, lon: -93.27, height: 250.0}

  @arcsec_tolerance 30.0

  describe "apparent_lon_lat/2 — Neptune @dt" do
    test "geocentric apparent lon matches reference oracle to 30 arcsec" do
      frame = ApparentPlace.frame(@dt, @observer)
      %{geocentric: {lon, _lat}} = ApparentPlace.apparent_lon_lat(frame, :neptune)
      oracle_lon = 3.80773539
      assert angular_diff_arcsec(lon, oracle_lon) < @arcsec_tolerance
    end

    test "topocentric apparent lon matches reference oracle to 30 arcsec" do
      frame = ApparentPlace.frame(@dt, @observer)
      %{topocentric: {lon, _lat}} = ApparentPlace.apparent_lon_lat(frame, :neptune)
      oracle_lon = 3.80778605
      assert angular_diff_arcsec(lon, oracle_lon) < @arcsec_tolerance
    end
  end

  describe "apparent_lon_lat/2 — Venus @dt" do
    test "geocentric apparent lon matches reference oracle to 30 arcsec" do
      frame = ApparentPlace.frame(@dt, @observer)
      %{geocentric: {lon, _lat}} = ApparentPlace.apparent_lon_lat(frame, :venus)
      oracle_lon = 91.6614261
      assert angular_diff_arcsec(lon, oracle_lon) < @arcsec_tolerance
    end

    test "topocentric apparent lon matches reference oracle to 30 arcsec" do
      frame = ApparentPlace.frame(@dt, @observer)
      %{topocentric: {lon, _lat}} = ApparentPlace.apparent_lon_lat(frame, :venus)
      oracle_lon = 91.66204283
      assert angular_diff_arcsec(lon, oracle_lon) < @arcsec_tolerance
    end
  end

  describe "apparent_lon_lat/2 — aberration" do
    test "geocentric apparent lon differs from geometric snapshot lon" do
      frame = ApparentPlace.frame(@dt, @observer)

      %{geocentric: {apparent_lon, _apparent_lat}} =
        ApparentPlace.apparent_lon_lat(frame, :neptune)

      {:ok, obs} = EphCore.SnapshotPipeline.observe(@dt, @observer, [:neptune])
      geometric_lon = obs.solar_system_positions[:neptune].ecliptic_longitude

      diff_arcsec = angular_diff_arcsec(apparent_lon, geometric_lon)
      assert diff_arcsec > 5.0
      assert diff_arcsec < 20.0
    end
  end

  defp angular_diff_arcsec(a, b) do
    d = abs(a - b)
    min(d, 360.0 - d) * 3600.0
  end
end
