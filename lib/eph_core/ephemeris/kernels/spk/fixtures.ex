defmodule EphCore.Ephemeris.Kernels.SPK.Fixtures do
  @moduledoc false

  alias EphCore.Ephemeris.Kernels.SPK.{Segment, Type2}

  @au_km 149_597_870.7

  # Approximate mean distances from Sun in AU (for fixture positioning)
  @distances %{
    mercury: 0.39,
    venus: 0.72,
    earth: 1.0,
    mars: 1.52,
    jupiter: 5.2,
    saturn: 9.5,
    uranus: 19.2,
    neptune: 30.0,
    pluto: 39.5
  }

  @spec load(atom()) :: {:ok, %{segments: [Segment.t()], entries: [map()]}} | {:error, term()}
  def load(:simple) do
    epoch_start = -1.0e9
    epoch_end = 1.0e9
    type2 = %Type2{init: epoch_start, intlen: epoch_end - epoch_start, rsize: 8, n: 1}
    record_radius = 1.0e9

    # All body barycenters relative to SSB (Solar System Barycenter)
    # Sun is at SSB origin (approximately)
    segments = [
      # Sun relative to SSB (at origin)
      segment(10, 0, epoch_start, epoch_end),
      # Planet barycenters relative to SSB
      segment(1, 0, epoch_start, epoch_end),
      segment(2, 0, epoch_start, epoch_end),
      segment(3, 0, epoch_start, epoch_end),
      segment(4, 0, epoch_start, epoch_end),
      segment(5, 0, epoch_start, epoch_end),
      segment(6, 0, epoch_start, epoch_end),
      segment(7, 0, epoch_start, epoch_end),
      segment(8, 0, epoch_start, epoch_end),
      segment(9, 0, epoch_start, epoch_end),
      # Earth and Moon relative to EMB
      segment(399, 3, epoch_start, epoch_end),
      segment(301, 3, epoch_start, epoch_end)
    ]

    entries = [
      # Sun at origin
      entry(Enum.at(segments, 0), type2, record(0.0, record_radius, {0.0, 0.0})),
      # Mercury at ~0.39 AU
      entry(
        Enum.at(segments, 1),
        type2,
        record(0.0, record_radius, {@au_km * @distances.mercury, 0.0})
      ),
      # Venus at ~0.72 AU
      entry(
        Enum.at(segments, 2),
        type2,
        record(0.0, record_radius, {@au_km * @distances.venus, 0.0})
      ),
      # EMB at ~1 AU
      entry(
        Enum.at(segments, 3),
        type2,
        record(0.0, record_radius, {@au_km * @distances.earth, 0.0})
      ),
      # Mars at ~1.52 AU
      entry(
        Enum.at(segments, 4),
        type2,
        record(0.0, record_radius, {@au_km * @distances.mars, 0.0})
      ),
      # Jupiter at ~5.2 AU
      entry(
        Enum.at(segments, 5),
        type2,
        record(0.0, record_radius, {@au_km * @distances.jupiter, 0.0})
      ),
      # Saturn at ~9.5 AU
      entry(
        Enum.at(segments, 6),
        type2,
        record(0.0, record_radius, {@au_km * @distances.saturn, 0.0})
      ),
      # Uranus at ~19.2 AU
      entry(
        Enum.at(segments, 7),
        type2,
        record(0.0, record_radius, {@au_km * @distances.uranus, 0.0})
      ),
      # Neptune at ~30 AU
      entry(
        Enum.at(segments, 8),
        type2,
        record(0.0, record_radius, {@au_km * @distances.neptune, 0.0})
      ),
      # Pluto at ~39.5 AU
      entry(
        Enum.at(segments, 9),
        type2,
        record(0.0, record_radius, {@au_km * @distances.pluto, 0.0})
      ),
      # Earth offset from EMB (about 4670 km toward anti-Moon direction)
      entry(Enum.at(segments, 10), type2, record(0.0, record_radius, {-4670.0, 0.0})),
      # Moon offset from EMB (about 379730 km toward Moon direction)
      entry(Enum.at(segments, 11), type2, record(0.0, record_radius, {379_730.0, 0.0}))
    ]

    {:ok, %{segments: segments, entries: entries}}
  end

  def load(_), do: {:error, :unknown_fixture}

  defp segment(target, center, start_epoch, end_epoch) do
    %Segment{
      target: target,
      center: center,
      frame: 1,
      data_type: 2,
      start_epoch: start_epoch,
      end_epoch: end_epoch,
      start_addr: 0,
      end_addr: 0
    }
  end

  defp entry(segment, type2, record) do
    %{segment: segment, type2: type2, records: [record]}
  end

  defp record(mid, radius, {x0, x1}) do
    %{
      mid: mid,
      radius: radius,
      coeff_x: [x0, x1],
      coeff_y: [0.0, 0.0],
      coeff_z: [0.0, 0.0]
    }
  end
end
