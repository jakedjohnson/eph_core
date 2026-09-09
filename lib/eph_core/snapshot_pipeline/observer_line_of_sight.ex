defmodule EphCore.SnapshotPipeline.ObserverLineOfSight do
  @moduledoc """
  Stage 05: OBSERVER_LINE_OF_SIGHT — shift from geocentric to topocentric.
  """

  alias AstroUtils.Vector
  alias EphCore.SnapshotPipeline.{ObserverPosition, Snapshot, SolarSystemPosition}
  alias EphCore.Telemetry

  defstruct [
    :target,
    :topocentric_position_km,
    :topocentric_range_km,
    :direction_unit,
    :aberration_applied,
    :frame
  ]

  @type t :: %__MODULE__{
          target: atom(),
          topocentric_position_km: {float(), float(), float()},
          topocentric_range_km: float(),
          direction_unit: {float(), float(), float()},
          aberration_applied: boolean(),
          frame: atom()
        }

  @spec resolve(term(), SolarSystemPosition.t()) :: t()
  def resolve(
        %Snapshot{observer_position: %ObserverPosition{inertial_position_km: observer_km}} =
          _snapshot,
        %SolarSystemPosition{} = solar_system_position
      ) do
    start = System.monotonic_time(:microsecond)
    Telemetry.stage_start(:observer_line_of_sight)

    topocentric_position_km =
      Vector.subtract(solar_system_position.geocentric_position_km, observer_km)

    topocentric_range_km = Vector.magnitude(topocentric_position_km)
    direction_unit = Vector.normalize(topocentric_position_km)

    duration = System.monotonic_time(:microsecond) - start

    Telemetry.stage_stop(:observer_line_of_sight, duration, %{
      target: solar_system_position.target
    })

    %__MODULE__{
      target: solar_system_position.target,
      topocentric_position_km: topocentric_position_km,
      topocentric_range_km: topocentric_range_km,
      direction_unit: direction_unit,
      aberration_applied: false,
      frame: solar_system_position.frame
    }
  end

  @spec resolve(term(), atom()) :: t()
  def resolve(%Snapshot{solar_system_positions: positions} = snapshot, target)
      when is_atom(target) do
    case Map.fetch(positions || %{}, target) do
      {:ok, solar_system_position} -> resolve(snapshot, solar_system_position)
      :error -> raise ArgumentError, "missing solar system position for #{inspect(target)}"
    end
  end
end
