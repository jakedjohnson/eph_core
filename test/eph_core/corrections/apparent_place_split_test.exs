defmodule EphCore.Corrections.ApparentPlaceSplitTest do
  use ExUnit.Case, async: false

  alias EphCore.Corrections.ApparentPlace

  @dt ~U[2026-05-20 10:27:49Z]
  @body :moon
  @observers [
    %{lat: 41.8781, lon: -87.6298, height: 181.0},
    %{lat: 34.0522, lon: -118.2437, height: 89.0},
    %{lat: 51.5074, lon: -0.1278, height: 35.0}
  ]
  @tolerance 1.0e-9

  test "shared geocentric apparent state projects to the same look as the unsplit path" do
    context = ApparentPlace.time_context(@dt)
    shared = ApparentPlace.geocentric_apparent(context, @body)

    for observer <- @observers do
      split_frame = ApparentPlace.frame(context, observer)
      full_frame = ApparentPlace.frame(@dt, observer)

      split = ApparentPlace.project(shared, split_frame)
      full = ApparentPlace.look(full_frame, @body)

      assert_close(split.alt_deg, full.alt_deg)
      assert_close(split.az_deg, full.az_deg)
      assert_close(split.hour_angle_deg, full.hour_angle_deg)
      assert_close(split.declination_deg, full.declination_deg)
      assert_close(split.range_km, full.range_km)
    end
  end

  defp assert_close(actual, expected) do
    assert_in_delta actual, expected, @tolerance
  end
end
