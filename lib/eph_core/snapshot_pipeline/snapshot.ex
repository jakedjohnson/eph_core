defmodule EphCore.SnapshotPipeline.Snapshot do
  @moduledoc false

  alias EphCore.SnapshotPipeline.{
    AstronomicalTime,
    EarthOrientation,
    ObserverPosition,
    SkyPosition,
    SolarSystemPosition
  }

  alias EphCore.SnapshotPipeline.Intent

  @enforce_keys [:intent]
  defstruct [
    :intent,
    :astronomical_time,
    :true_of_date_nutation,
    :earth_orientation,
    :observer_position,
    :solar_system_positions,
    :sky_positions,
    :motion
  ]

  @type t :: %__MODULE__{
          intent: Intent.t(),
          astronomical_time: AstronomicalTime.t() | nil,
          true_of_date_nutation: {float(), float()} | nil,
          earth_orientation: EarthOrientation.t() | nil,
          observer_position: ObserverPosition.t() | nil,
          solar_system_positions: %{optional(atom()) => SolarSystemPosition.t()} | nil,
          sky_positions: %{optional(atom()) => SkyPosition.t()} | nil,
          motion: %{optional(atom()) => map()} | nil
        }

  @doc """
  Create a new snapshot from an intent struct.
  """
  @spec new(Intent.t()) :: t()
  def new(%Intent{} = intent) do
    %__MODULE__{intent: intent}
  end
end
