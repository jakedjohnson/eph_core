defmodule EphCore.SnapshotPipeline.ApparentPipelineTest do
  use ExUnit.Case, async: false

  alias EphCore.Corrections.ApparentPlace

  @dt ~U[2026-07-07 10:54:38Z]
  @observer %{lat: 44.98, lon: -93.27, height: 250.0}
  # Tolerance: 0.01 degrees = 36 arcseconds
  @deg_tolerance 0.01

  describe "apparent geocentric ecliptic longitude in pipeline" do
    test "apparent_geocentric_ecliptic_longitude is populated for Neptune when flags are set" do
      {:ok, obs} =
        EphCore.SnapshotPipeline.observe(
          @dt,
          @observer,
          [:neptune],
          corrections: %{aberration: true, light_time: true},
          parallel: false
        )

      neptune_pos = obs.solar_system_positions[:neptune]
      assert neptune_pos != nil
      assert neptune_pos.apparent_geocentric_ecliptic_longitude != nil
      assert neptune_pos.apparent_geocentric_ecliptic_latitude != nil
      assert is_float(neptune_pos.apparent_geocentric_ecliptic_longitude)
    end

    test "apparent_geocentric_ecliptic_longitude matches ApparentPlace.apparent_lon_lat geocentric" do
      # Compute expected value directly via ApparentPlace
      frame = ApparentPlace.frame(@dt, %{lat: 0.0, lon: 0.0, height: 0.0})

      %{geocentric: {expected_lon, expected_lat}} =
        ApparentPlace.apparent_lon_lat(frame, :neptune)

      {:ok, obs} =
        EphCore.SnapshotPipeline.observe(
          @dt,
          @observer,
          [:neptune],
          corrections: %{aberration: true, light_time: true},
          parallel: false
        )

      neptune_pos = obs.solar_system_positions[:neptune]

      assert_in_delta neptune_pos.apparent_geocentric_ecliptic_longitude,
                      expected_lon,
                      @deg_tolerance

      assert_in_delta neptune_pos.apparent_geocentric_ecliptic_latitude,
                      expected_lat,
                      @deg_tolerance
    end

    test "apparent_geocentric_ecliptic_longitude is nil when flags are false (default)" do
      {:ok, obs} =
        EphCore.SnapshotPipeline.observe(
          @dt,
          @observer,
          [:neptune],
          parallel: false
        )

      neptune_pos = obs.solar_system_positions[:neptune]
      assert neptune_pos.apparent_geocentric_ecliptic_longitude == nil
      assert neptune_pos.apparent_geocentric_ecliptic_latitude == nil
    end

    test "apparent longitude differs from geometric longitude by at most 0.01 degrees for Neptune" do
      {:ok, obs_apparent} =
        EphCore.SnapshotPipeline.observe(
          @dt,
          @observer,
          [:neptune],
          corrections: %{aberration: true, light_time: true},
          parallel: false
        )

      {:ok, obs_geometric} =
        EphCore.SnapshotPipeline.observe(
          @dt,
          @observer,
          [:neptune],
          parallel: false
        )

      apparent_lon =
        obs_apparent.solar_system_positions[:neptune].apparent_geocentric_ecliptic_longitude

      geometric_lon = obs_geometric.solar_system_positions[:neptune].ecliptic_longitude

      # Apparent and geometric should be within a small range of each other for a slow body like Neptune
      diff = abs(apparent_lon - geometric_lon)
      diff = min(diff, 360.0 - diff)
      # Should differ by some amount (aberration is real) but not hugely
      # Light-time + aberration for Neptune is typically < 0.005 degrees
      assert diff < 0.01
    end

    test "geometric fields are still present and non-nil regardless of apparent flag" do
      {:ok, obs} =
        EphCore.SnapshotPipeline.observe(
          @dt,
          @observer,
          [:neptune],
          corrections: %{aberration: true, light_time: true},
          parallel: false
        )

      neptune_pos = obs.solar_system_positions[:neptune]
      assert neptune_pos.ecliptic_longitude != nil
      assert neptune_pos.ecliptic_latitude != nil
    end
  end

  describe "apparent geocentric lon-rate in motion" do
    test "apparent_geocentric_ecliptic_lon_rate_deg_per_day is present when flags are set" do
      {:ok, obs} =
        EphCore.SnapshotPipeline.observe(
          @dt,
          @observer,
          [:neptune],
          corrections: %{aberration: true, light_time: true},
          motion: %{enabled: true, dt_minutes: 30},
          parallel: false
        )

      assert obs.motion != nil
      neptune_motion = obs.motion[:neptune]
      assert neptune_motion != nil
      assert Map.has_key?(neptune_motion, :apparent_geocentric_ecliptic_lon_rate_deg_per_day)
      assert is_float(neptune_motion.apparent_geocentric_ecliptic_lon_rate_deg_per_day)
    end

    test "apparent_geocentric_ecliptic_lon_rate_deg_per_day is absent when flags are false" do
      {:ok, obs} =
        EphCore.SnapshotPipeline.observe(
          @dt,
          @observer,
          [:neptune],
          motion: %{enabled: true, dt_minutes: 30},
          parallel: false
        )

      neptune_motion = obs.motion[:neptune]
      refute Map.has_key?(neptune_motion, :apparent_geocentric_ecliptic_lon_rate_deg_per_day)
      # Standard geometric rate is still present
      assert Map.has_key?(neptune_motion, :ecliptic_lon_rate_deg_per_day)
    end

    test "geometric ecliptic_lon_rate_deg_per_day is still present alongside apparent rate" do
      {:ok, obs} =
        EphCore.SnapshotPipeline.observe(
          @dt,
          @observer,
          [:neptune],
          corrections: %{aberration: true, light_time: true},
          motion: %{enabled: true, dt_minutes: 30},
          parallel: false
        )

      neptune_motion = obs.motion[:neptune]
      assert Map.has_key?(neptune_motion, :ecliptic_lon_rate_deg_per_day)
      assert Map.has_key?(neptune_motion, :apparent_geocentric_ecliptic_lon_rate_deg_per_day)
    end

    test "Neptune apparent rate near station is near zero" do
      # Neptune is near its retrograde station on 2026-07-07; rate should be very small
      {:ok, obs} =
        EphCore.SnapshotPipeline.observe(
          @dt,
          @observer,
          [:neptune],
          corrections: %{aberration: true, light_time: true},
          motion: %{enabled: true, dt_minutes: 30},
          parallel: false
        )

      rate = obs.motion[:neptune].apparent_geocentric_ecliptic_lon_rate_deg_per_day
      # Near station, rate should be very small (less than 0.01 deg/day)
      assert abs(rate) < 0.01
    end
  end
end
