defmodule EphCore do
  @moduledoc """
  EphCore computes celestial positions from a UTC instant and observer location.

  The primary entry point is `observe/4`, which runs the snapshot pipeline and
  returns an `%EphCore.SnapshotPipeline.Observation{}` with sky positions,
  ephemeris coordinates, and optional motion rates for the requested bodies.

  ## Example

      datetime = ~U[2026-02-02 12:00:00Z]
      location = %{lat: 44.9778, lon: -93.2650, height: 250}

      {:ok, observation} = EphCore.observe(datetime, location, [:sun, :moon])

      observation.bodies[:sun].altitude_deg
      observation.solar_system_positions[:sun].ecliptic_longitude

  See `EphCore.SnapshotPipeline` for option keys (`:models`, `:corrections`,
  `:motion`, and `:geometry`).
  """

  @doc """
  Compute sky positions for celestial bodies from a given location and time.

  Delegates to `EphCore.SnapshotPipeline.observe/4`. See that module for options
  and return structure.
  """
  defdelegate observe(datetime, location, bodies, opts \\ []), to: EphCore.SnapshotPipeline
end
