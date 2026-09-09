defmodule EphCore.SnapshotPipeline.Intent do
  @moduledoc """
  Stage 00: INTENT — validate and normalize the request that drives the pipeline.

  `EphCore.observe/4` builds an intent from its arguments before any astronomy
  runs. Invalid input fails here with `{:error, %Ecto.Changeset{}}` rather than
  partway through a computation, and every later stage reads its settings from
  the resulting immutable struct.

  ## Fields

  - `:utc` — required `DateTime` in UTC.
  - `:observer` — `%{lat_deg:, lon_deg:, height_m:}` (WGS84), normalized from
    `%{lat:, lon:, height:}`.
  - `:targets` — supported body atoms (planets, `:sun`, `:moon`, `:pluto`, and
    the asteroids `:ceres`, `:pallas`, `:juno`, `:vesta`, `:chiron`).
  - `:models` — `:delta_t`, `:earth_orientation`, `:earth`, `:ecliptic_frame`.
  - `:corrections` — `:precession_nutation`, `:aberration`, `:light_time`.
  - `:motion` — `:enabled` and `:dt_minutes` (1..1440).
  - `:geometry` — `:ring_samples` (`0`, or clamped to 8..72).

  Omitted keys fall back to defaults: IERS ΔT, GMST, WGS84, true-of-date
  ecliptic, no corrections, motion enabled at a 30-minute half-window, and 24
  ring samples. See the README options reference for what each value changes.

  ## Example

      {:ok, snapshot} =
        Intent.new(%{
          utc: ~U[2026-01-12 17:32:10Z],
          observer: %{lat: 44.9778, lon: -93.2650, height: 250},
          targets: [:sun, :moon],
          models: %{ecliptic_frame: :mean_of_date}
        })

  `new/1` returns an internal snapshot struct wrapping the intent, which then
  accumulates each stage's results as it flows through the pipeline.
  """

  import Ecto.Changeset

  alias EphCore.SnapshotPipeline.Snapshot

  @delta_t_models [:approximate, :iers]
  @earth_orientation_models [:gmst, :gast]
  @earth_models [:wgs84]
  @ecliptic_frame_models [:j2000, :mean_of_date, :true_of_date]
  @supported_targets [
    :sun,
    :moon,
    :mercury,
    :venus,
    :mars,
    :jupiter,
    :saturn,
    :uranus,
    :neptune,
    :pluto,
    :ceres,
    :pallas,
    :juno,
    :vesta,
    :chiron
  ]
  @default_motion %{enabled: true, dt_minutes: 30}
  @default_ring_samples 24
  @min_ring_samples 8
  @max_ring_samples 72
  @default_geometry %{ring_samples: @default_ring_samples}
  @min_motion_dt_minutes 1
  @max_motion_dt_minutes 1440

  defstruct [:utc, :observer, :targets, :models, :corrections, :motion, :geometry]

  @type observer :: %{
          lat_deg: float(),
          lon_deg: float(),
          height_m: float()
        }

  @type t :: %__MODULE__{
          utc: DateTime.t(),
          observer: observer() | nil,
          targets: [atom()] | nil,
          models: %{
            delta_t: atom(),
            earth_orientation: atom(),
            earth: atom(),
            ecliptic_frame: atom()
          },
          corrections: %{
            precession_nutation: boolean(),
            aberration: boolean(),
            light_time: boolean()
          },
          motion: %{enabled: boolean(), dt_minutes: integer()},
          geometry: %{ring_samples: integer()}
        }

  @doc """
  Build a new snapshot from intent params.

  Returns `{:ok, %Snapshot{}}` on success, otherwise `{:error, changeset}`.
  """
  @spec new(map() | keyword()) :: {:ok, term()} | {:error, Ecto.Changeset.t()}
  def new(params) when is_map(params) or is_list(params) do
    params = normalize_params(params)
    changeset = changeset(params)

    if changeset.valid? do
      intent = apply_changes(changeset)
      {:ok, Snapshot.new(intent)}
    else
      {:error, changeset}
    end
  end

  @doc """
  Build the intent changeset without persisting data.
  """
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(params) when is_map(params) do
    types = %{
      utc: :utc_datetime,
      observer: :map,
      targets: :any,
      models: :map,
      corrections: :map,
      motion: :map,
      geometry: :map
    }

    {%__MODULE__{}, types}
    |> cast(params, Map.keys(types))
    |> validate_required([:utc])
    |> validate_change(:utc, &validate_utc/2)
    |> validate_change(:observer, &validate_observer/2)
    |> validate_change(:targets, &validate_targets/2)
    |> validate_change(:models, &validate_models/2)
    |> validate_change(:corrections, &validate_corrections/2)
    |> validate_change(:motion, &validate_motion/2)
    |> validate_change(:geometry, &validate_geometry/2)
  end

  defp normalize_params(params) do
    params
    |> Enum.into(%{})
    |> normalize_observer()
    |> normalize_targets()
    |> Map.update(
      :models,
      %{delta_t: :iers, earth_orientation: :gmst, earth: :wgs84, ecliptic_frame: :true_of_date},
      &normalize_models/1
    )
    |> Map.update(
      :corrections,
      %{precession_nutation: false, aberration: false, light_time: false},
      &normalize_corrections/1
    )
    |> Map.update(:motion, @default_motion, &normalize_motion/1)
    |> Map.update(:geometry, @default_geometry, &normalize_geometry/1)
  end

  defp normalize_observer(%{observer: %{lat: lat, lon: lon}} = params) do
    # Support shorthand :lat/:lon keys, convert to canonical :lat_deg/:lon_deg
    observer = %{
      lat_deg: params.observer[:lat_deg] || lat,
      lon_deg: params.observer[:lon_deg] || lon,
      height_m: params.observer[:height_m] || params.observer[:height] || 0.0
    }

    Map.put(params, :observer, observer)
  end

  defp normalize_observer(%{observer: observer} = params) when is_map(observer) do
    normalized = %{
      lat_deg: observer[:lat_deg] || observer[:lat] || 0.0,
      lon_deg: observer[:lon_deg] || observer[:lon] || 0.0,
      height_m: observer[:height_m] || observer[:height] || 0.0
    }

    Map.put(params, :observer, normalized)
  end

  defp normalize_observer(params), do: params

  defp normalize_targets(%{targets: targets} = params) when is_list(targets) do
    # Ensure targets are atoms
    normalized =
      Enum.map(targets, fn
        t when is_atom(t) -> t
        t when is_binary(t) -> String.to_existing_atom(t)
      end)

    Map.put(params, :targets, normalized)
  end

  defp normalize_targets(params), do: params

  defp normalize_models(models) when is_map(models) do
    models
    |> Map.put_new(:delta_t, :iers)
    |> Map.put_new(:earth_orientation, :gmst)
    |> Map.put_new(:earth, :wgs84)
    |> Map.put_new(:ecliptic_frame, :true_of_date)
  end

  defp normalize_models(_models) do
    %{delta_t: :iers, earth_orientation: :gmst, earth: :wgs84, ecliptic_frame: :true_of_date}
  end

  defp normalize_corrections(corrections) when is_map(corrections) do
    corrections
    |> Map.put_new(:precession_nutation, false)
    |> Map.put_new(:aberration, false)
    |> Map.put_new(:light_time, false)
  end

  defp normalize_corrections(_corrections) do
    %{precession_nutation: false, aberration: false, light_time: false}
  end

  defp normalize_motion(motion) when is_map(motion) do
    motion
    |> Map.put_new(:enabled, @default_motion.enabled)
    |> Map.put_new(:dt_minutes, @default_motion.dt_minutes)
  end

  defp normalize_motion(_motion), do: @default_motion

  defp normalize_geometry(geometry) when is_map(geometry) do
    ring_samples_value = Map.get(geometry, :ring_samples, Map.get(geometry, "ring_samples"))

    ring_samples =
      case normalize_ring_samples(ring_samples_value) do
        {:ok, value} -> value
        {:error, _} -> ring_samples_value
      end

    %{ring_samples: ring_samples}
  end

  defp normalize_geometry(_geometry), do: @default_geometry

  defp validate_utc(:utc, %DateTime{} = value) do
    if value.time_zone == "Etc/UTC" or value.time_zone == "UTC" do
      []
    else
      [utc: "must be in UTC"]
    end
  end

  defp validate_utc(:utc, _value) do
    [utc: "must be a DateTime"]
  end

  defp validate_observer(:observer, %{} = observer) do
    lat = Map.get(observer, :lat_deg)
    lon = Map.get(observer, :lon_deg)
    height = Map.get(observer, :height_m)

    errors = []

    errors =
      cond do
        not is_number(lat) -> [observer: "lat_deg must be a number"] ++ errors
        lat < -90.0 or lat > 90.0 -> [observer: "lat_deg must be between -90 and +90"] ++ errors
        true -> errors
      end

    errors =
      cond do
        not is_number(lon) ->
          [observer: "lon_deg must be a number"] ++ errors

        lon < -180.0 or lon > 180.0 ->
          [observer: "lon_deg must be between -180 and +180"] ++ errors

        true ->
          errors
      end

    errors =
      if not is_number(height) do
        [observer: "height_m must be a number"] ++ errors
      else
        errors
      end

    errors
  end

  defp validate_observer(:observer, _value) do
    [observer: "must be a map with lat_deg, lon_deg, and height_m"]
  end

  defp validate_targets(:targets, targets) when is_list(targets) do
    invalid = Enum.reject(targets, &(&1 in @supported_targets))

    if Enum.empty?(invalid) do
      []
    else
      [
        targets:
          "unsupported targets: #{inspect(invalid)}. Supported: #{inspect(@supported_targets)}"
      ]
    end
  end

  defp validate_targets(:targets, _value) do
    [targets: "must be a list of target atoms"]
  end

  defp validate_models(:models, %{} = models) do
    delta_t = Map.get(models, :delta_t, :approximate)
    earth_orientation = Map.get(models, :earth_orientation, :gmst)
    earth = Map.get(models, :earth, :wgs84)
    ecliptic_frame = Map.get(models, :ecliptic_frame, :true_of_date)

    errors = []

    errors =
      if delta_t in @delta_t_models do
        errors
      else
        [models: "delta_t must be one of #{inspect(@delta_t_models)}"] ++ errors
      end

    errors =
      if earth_orientation in @earth_orientation_models do
        errors
      else
        [models: "earth_orientation must be one of #{inspect(@earth_orientation_models)}"] ++
          errors
      end

    errors =
      if earth in @earth_models do
        errors
      else
        [models: "earth must be one of #{inspect(@earth_models)}"] ++ errors
      end

    errors =
      if ecliptic_frame in @ecliptic_frame_models do
        errors
      else
        [models: "ecliptic_frame must be one of #{inspect(@ecliptic_frame_models)}"] ++ errors
      end

    errors
  end

  defp validate_models(:models, _value) do
    [models: "must be a map"]
  end

  defp validate_corrections(:corrections, %{} = corrections) do
    precession_nutation = Map.get(corrections, :precession_nutation, false)
    aberration = Map.get(corrections, :aberration, false)
    light_time = Map.get(corrections, :light_time, false)

    errors = []

    errors =
      if is_boolean(precession_nutation) do
        errors
      else
        [corrections: "precession_nutation must be boolean"] ++ errors
      end

    errors =
      if is_boolean(aberration) do
        errors
      else
        [corrections: "aberration must be boolean"] ++ errors
      end

    errors =
      if is_boolean(light_time) do
        errors
      else
        [corrections: "light_time must be boolean"] ++ errors
      end

    errors
  end

  defp validate_corrections(:corrections, _value) do
    [corrections: "must be a map"]
  end

  @doc """
  Returns `true` when both `aberration` and `light_time` correction flags are enabled,
  meaning apparent geocentric position should be computed.
  """
  @spec apparent_geocentric?(t()) :: boolean()
  def apparent_geocentric?(%__MODULE__{corrections: corrections}) do
    Map.get(corrections, :aberration, false) and Map.get(corrections, :light_time, false)
  end

  defp validate_motion(:motion, %{} = motion) do
    enabled = Map.get(motion, :enabled, @default_motion.enabled)
    dt_minutes = Map.get(motion, :dt_minutes, @default_motion.dt_minutes)

    errors = []

    errors =
      if is_boolean(enabled) do
        errors
      else
        [motion: "enabled must be boolean"] ++ errors
      end

    errors =
      if is_integer(dt_minutes) and dt_minutes >= @min_motion_dt_minutes and
           dt_minutes <= @max_motion_dt_minutes do
        errors
      else
        [
          motion:
            "dt_minutes must be an integer in #{@min_motion_dt_minutes}-#{@max_motion_dt_minutes}"
        ] ++ errors
      end

    errors
  end

  defp validate_motion(:motion, _value) do
    [motion: "must be a map"]
  end

  defp validate_geometry(:geometry, %{} = geometry) do
    ring_samples =
      Map.get(geometry, :ring_samples, Map.get(geometry, "ring_samples", @default_ring_samples))

    case normalize_ring_samples(ring_samples) do
      {:ok, _} -> []
      {:error, message} -> [geometry: message]
    end
  end

  defp validate_geometry(:geometry, _value) do
    [geometry: "must be a map"]
  end

  defp normalize_ring_samples(nil), do: {:ok, @default_ring_samples}

  defp normalize_ring_samples(value) when is_integer(value) do
    cond do
      value < 0 -> {:error, "ring_samples must be greater than or equal to 0"}
      value == 0 -> {:ok, 0}
      value < @min_ring_samples -> {:ok, @min_ring_samples}
      value > @max_ring_samples -> {:ok, @max_ring_samples}
      true -> {:ok, value}
    end
  end

  defp normalize_ring_samples(value) when is_float(value) do
    if value == trunc(value) do
      normalize_ring_samples(trunc(value))
    else
      {:error, "ring_samples must be an integer"}
    end
  end

  defp normalize_ring_samples(_value), do: {:error, "ring_samples must be an integer"}
end
