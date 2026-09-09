defmodule EphCore.TimeSeriesTest do
  use ExUnit.Case, async: false

  describe "compute/2" do
    test "returns parallel arrays aligned with input timestamps" do
      timestamps = [
        ~U[2026-05-20 10:00:00Z],
        ~U[2026-05-20 10:15:00Z],
        ~U[2026-05-20 10:30:00Z]
      ]

      {:ok, grid} = EphCore.TimeSeries.compute(timestamps, [:venus, :mars])

      assert grid.timestamps == timestamps
      assert length(grid.positions[:venus]) == 3
      assert length(grid.positions[:mars]) == 3
      assert length(grid.motion[:venus]) == 3
      assert length(grid.motion[:mars]) == 3
    end

    test "ecliptic longitudes are within 0.01° of observe/4 at same timestamps" do
      dt = ~U[2026-05-20 10:00:00Z]
      bodies = [:venus, :sun, :mars]

      {:ok, grid} = EphCore.TimeSeries.compute([dt], bodies)

      {:ok, obs} =
        EphCore.SnapshotPipeline.observe(
          dt,
          %{lat: 0.0, lon: 0.0, height: 0.0},
          bodies
        )

      for body <- bodies do
        ts_lon = hd(grid.positions[body])
        obs_lon = obs.solar_system_positions[body].ecliptic_longitude

        assert abs(ts_lon - obs_lon) < 0.01,
               "#{body} longitude differs: TimeSeries=#{ts_lon}, observe/4=#{obs_lon}"
      end
    end

    test "topocentric longitudes/declinations match observe/4 when observer supplied" do
      dt = ~U[2026-05-20 10:00:00Z]
      bodies = [:moon, :venus, :mars]
      observer = %{lat: 44.98, lon: -93.27, height: 250.0}

      {:ok, grid} = EphCore.TimeSeries.compute([dt], bodies, observer: observer)

      {:ok, obs} = EphCore.SnapshotPipeline.observe(dt, observer, bodies)

      for body <- bodies do
        ts_lon = hd(grid.positions[body])
        ts_dec = hd(grid.declinations[body])
        obs_lon = obs.bodies[body].topocentric_ecliptic_longitude
        obs_dec = obs.bodies[body].topocentric_declination

        assert abs(ts_lon - obs_lon) < 0.01,
               "#{body} topo longitude differs: TimeSeries=#{ts_lon}, observe/4=#{obs_lon}"

        assert abs(ts_dec - obs_dec) < 0.01,
               "#{body} topo declination differs: TimeSeries=#{ts_dec}, observe/4=#{obs_dec}"
      end
    end

    test "topocentric Moon longitude differs from geocentric by parallax (>0.1°)" do
      dt = ~U[2026-05-20 10:00:00Z]
      observer = %{lat: 44.98, lon: -93.27, height: 250.0}

      {:ok, geo} = EphCore.TimeSeries.compute([dt], [:moon])
      {:ok, topo} = EphCore.TimeSeries.compute([dt], [:moon], observer: observer)

      geo_lon = hd(geo.positions[:moon])
      topo_lon = hd(topo.positions[:moon])

      assert abs(geo_lon - topo_lon) > 0.1,
             "Moon parallax should shift longitude noticeably (geo=#{geo_lon}, topo=#{topo_lon})"
    end

    test "motion rates have correct sign for well-known retrograde bodies" do
      # Jupiter and Saturn are direct in May 2026
      # Pluto is retrograde in May 2026
      timestamps = [
        ~U[2026-05-20 10:00:00Z],
        ~U[2026-05-20 10:15:00Z],
        ~U[2026-05-20 10:30:00Z]
      ]

      {:ok, grid} = EphCore.TimeSeries.compute(timestamps, [:jupiter, :pluto])

      jupiter_rate = Enum.at(grid.motion[:jupiter], 1)
      pluto_rate = Enum.at(grid.motion[:pluto], 1)

      assert jupiter_rate > 0, "Jupiter should be direct in May 2026 (rate=#{jupiter_rate})"
      assert pluto_rate < 0, "Pluto should be retrograde in May 2026 (rate=#{pluto_rate})"
    end

    test "handles single timestamp" do
      {:ok, grid} = EphCore.TimeSeries.compute([~U[2026-05-20 10:00:00Z]], [:sun])
      assert length(grid.positions[:sun]) == 1
      assert length(grid.motion[:sun]) == 1
    end

    test "longitudes are in range 0-360" do
      timestamps =
        Enum.map(0..9, fn i ->
          DateTime.add(~U[2026-05-20 00:00:00Z], i * 3600, :second)
        end)

      {:ok, grid} = EphCore.TimeSeries.compute(timestamps, [:sun, :moon, :venus])

      for {_body, lons} <- grid.positions, lon <- lons do
        assert lon >= 0.0 and lon < 360.0, "Longitude out of range: #{lon}"
      end
    end
  end

  describe "add_horizon_geometry/2" do
    test "adds horizon columns aligned with timestamps" do
      timestamps = [
        ~U[2026-05-20 10:00:00Z],
        ~U[2026-05-20 11:00:00Z]
      ]

      observer = %{lat: 44.98, lon: -93.27, height: 250.0}
      bodies = [:sun, :moon]

      {:ok, grid} = EphCore.TimeSeries.compute(timestamps, bodies, observer: observer)
      enriched = EphCore.TimeSeries.add_horizon_geometry(grid, observer)

      assert length(enriched.axes.mc) == 2
      assert length(enriched.axes.asc) == 2
      assert length(enriched.lst) == 2
      assert length(enriched.obliquity_deg) == 2
      assert enriched.observer_lat == observer.lat

      for body <- bodies do
        assert length(enriched.altitudes[body]) == 2
        assert length(enriched.azimuths[body]) == 2
      end
    end

    test "altitudes are within physical range" do
      timestamps = [~U[2026-05-20 12:00:00Z]]
      observer = %{lat: 44.98, lon: -93.27, height: 250.0}

      {:ok, grid} = EphCore.TimeSeries.compute(timestamps, [:sun], observer: observer)
      enriched = EphCore.TimeSeries.add_horizon_geometry(grid, observer)

      sun_alt = hd(enriched.altitudes[:sun])
      assert sun_alt >= -90.0 and sun_alt <= 90.0
    end
  end
end
