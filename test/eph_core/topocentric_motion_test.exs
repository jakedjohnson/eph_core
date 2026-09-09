defmodule EphCore.TopocentricMotionTest do
  use ExUnit.Case, async: false

  @dt ~U[2026-05-20 10:00:00Z]
  @observer %{lat: 44.98, lon: -93.27, height: 250.0}
  @bodies [:moon, :venus, :pluto]

  describe "ecliptic_lon_rates/4" do
    test "returns a rate per body" do
      rates = EphCore.TopocentricMotion.ecliptic_lon_rates(@dt, @observer, @bodies)

      assert Map.keys(rates) |> Enum.sort() == Enum.sort(@bodies)
      assert is_number(rates[:moon])
    end

    test "Pluto is retrograde in May 2026" do
      rates = EphCore.TopocentricMotion.ecliptic_lon_rates(@dt, @observer, [:pluto])
      assert hd(Map.values(rates)) < 0
    end
  end

  describe "augment/5" do
    test "adds topocentric_ecliptic_lon_rate_deg_per_day to motion maps" do
      {:ok, obs} =
        EphCore.SnapshotPipeline.observe(@dt, @observer, @bodies,
          motion: %{enabled: true, dt_minutes: 30}
        )

      motion =
        EphCore.TopocentricMotion.augment(@dt, @observer, @bodies, obs.motion, delta_minutes: 30)

      for body <- @bodies do
        assert is_number(motion[body].topocentric_ecliptic_lon_rate_deg_per_day)
        assert is_number(motion[body].ecliptic_lon_rate_deg_per_day)
      end
    end
  end
end
