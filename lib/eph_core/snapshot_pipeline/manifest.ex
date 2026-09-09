defmodule EphCore.SnapshotPipeline.Manifest do
  @moduledoc false

  alias EphCore.SnapshotPipeline.{Observation, Snapshot}

  @spec finalize(term()) :: Observation.t()
  def finalize(%Snapshot{} = snapshot) do
    %Observation{
      intent: snapshot.intent,
      epoch: snapshot.astronomical_time,
      earth_orientation: snapshot.earth_orientation,
      observer_position: snapshot.observer_position,
      bodies: snapshot.sky_positions || %{},
      solar_system_positions: snapshot.solar_system_positions || %{},
      motion: snapshot.motion,
      computed_at: DateTime.utc_now(),
      engine_version: to_string(Application.spec(:eph_core, :vsn))
    }
  end
end
