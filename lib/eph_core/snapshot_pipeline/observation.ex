defmodule EphCore.SnapshotPipeline.Observation do
  @moduledoc """
  Result returned by `EphCore.observe/4`.

  ## Fields

  - `:bodies` — `%{body => EphCore.SnapshotPipeline.SkyPosition{}}`: altitude,
    azimuth, and topocentric coordinates as seen from the observer.
  - `:solar_system_positions` — `%{body => EphCore.SnapshotPipeline.SolarSystemPosition{}}`:
    geocentric ecliptic/equatorial coordinates and range.
  - `:motion` — `%{body => map}` of ecliptic longitude rates, or `nil` when
    motion is disabled.
  - `:intent` — the validated request (`EphCore.SnapshotPipeline.Intent`).
  - `:epoch`, `:earth_orientation`, `:observer_position` — the shared time,
    rotation, and observer context the bodies were computed against.
  - `:computed_at`, `:engine_version` — provenance for the computation.
  """

  alias EphCore.SnapshotPipeline.{
    AstronomicalTime,
    EarthOrientation,
    Intent,
    ObserverPosition,
    SkyPosition,
    SolarSystemPosition
  }

  defstruct [
    :intent,
    :epoch,
    :earth_orientation,
    :observer_position,
    :bodies,
    :solar_system_positions,
    :motion,
    :computed_at,
    :engine_version
  ]

  @type t :: %__MODULE__{
          intent: Intent.t(),
          epoch: AstronomicalTime.t(),
          earth_orientation: EarthOrientation.t(),
          observer_position: ObserverPosition.t(),
          bodies: %{optional(atom()) => SkyPosition.t()},
          solar_system_positions: %{optional(atom()) => SolarSystemPosition.t()},
          motion: %{optional(atom()) => map()} | nil,
          computed_at: DateTime.t(),
          engine_version: String.t()
        }
end
