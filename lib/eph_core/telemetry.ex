defmodule EphCore.Telemetry do
  @moduledoc false

  @prefix [:eph_core, :pipeline]

  def stage_start(stage) do
    :telemetry.execute(@prefix ++ [stage, :start], %{}, %{})
  end

  def stage_stop(stage, duration_us, metadata \\ %{}) do
    :telemetry.execute(@prefix ++ [stage, :stop], %{duration_us: duration_us}, metadata)
  end
end
