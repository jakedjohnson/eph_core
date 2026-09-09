defmodule EphCore.Ephemeris.Kernels.SPK.Server do
  @moduledoc """
  SPK kernel server with ETS preloading for fast queries.

  Supports SPK data types 2 (Chebyshev) and 21 (Extended Modified Difference
  Arrays). Multiple kernel files are loaded at startup and merged into a single
  ETS table.

  ## Configuration

      config :eph_core, :spk_kernels, ["de440s.bsp", "asteroids/2000001.bsp"]

  Paths are resolved relative to `ephemeris/spk/` under
  `EphCore.Ephemeris.Kernels.base_dir/0`. Falls back to `["de440s.bsp"]` when
  unset.

  ## ETS storage layout

  - `{:meta, target, center}` → list of segment metadata maps
  - `{:record, target, center, index}` → Type 2 Chebyshev record tuple
  - `{:t21_record, target, center, seg_start, index}` → Type 21 MDA record map
  """

  use GenServer

  alias EphCore.Ephemeris.Kernels

  alias EphCore.Ephemeris.Kernels.SPK.{
    Chebyshev,
    DAF,
    DifferenceArray,
    Fixtures,
    Segment,
    Type2,
    Type21
  }

  alias EphCore.Telemetry

  @table __MODULE__
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec position_at(integer(), integer(), float()) ::
          {:ok, {float(), float(), float()}} | {:error, term()}
  def position_at(target, center, seconds_past_j2000) do
    start = System.monotonic_time(:microsecond)
    Telemetry.stage_start(:spk_query)

    result =
      case :ets.lookup(@table, {:meta, target, center}) do
        [{_key, metas}] ->
          with {:ok, meta} <- find_meta(metas, seconds_past_j2000),
               {:ok, position} <- evaluate_at(target, center, meta, seconds_past_j2000) do
            {:ok, position}
          end

        [] ->
          {:error, :segment_not_found}
      end

    duration = System.monotonic_time(:microsecond) - start

    metadata = %{target: target, center: center}

    metadata =
      if match?({:error, _}, result),
        do: Map.put(metadata, :error, elem(result, 1)),
        else: metadata

    Telemetry.stage_stop(:spk_query, duration, metadata)

    result
  end

  @doc """
  Telemetry-free position query for hot paths (almanac event finding).

  Identical lookup to `position_at/3` but skips the per-query `:telemetry`
  emission and timing. Use only where the high query volume makes the telemetry
  overhead material and per-query metrics are not needed; the normal engine
  paths keep `position_at/3`.
  """
  @spec position_at_fast(integer(), integer(), float()) ::
          {:ok, {float(), float(), float()}} | {:error, term()}
  def position_at_fast(target, center, seconds_past_j2000) do
    case :ets.lookup(@table, {:meta, target, center}) do
      [{_key, metas}] ->
        with {:ok, meta} <- find_meta(metas, seconds_past_j2000),
             {:ok, position} <- evaluate_at(target, center, meta, seconds_past_j2000) do
          {:ok, position}
        end

      [] ->
        {:error, :segment_not_found}
    end
  end

  @spec loaded?() :: boolean()
  def loaded? do
    case :ets.info(@table) do
      :undefined -> false
      _ -> true
    end
  end

  @spec segments() :: [Segment.t()]
  def segments do
    GenServer.call(__MODULE__, :segments)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    case Application.get_env(:eph_core, :spk_fixture) do
      nil ->
        kernel_names = Application.get_env(:eph_core, :spk_kernels, ["de440s.bsp"])

        all_segments =
          kernel_names
          |> Enum.flat_map(fn name ->
            path = Kernels.spk_path(name)

            if File.exists?(path) do
              case load_kernel(path) do
                {:ok, segments} ->
                  segments

                {:error, reason} ->
                  Logger.warning("Failed to load SPK kernel #{path}: #{inspect(reason)}")
                  []
              end
            else
              Logger.warning("SPK kernel missing at #{path}. Run mix eph.download_kernels.")
              []
            end
          end)

        {:ok, %{kernels: kernel_names, segments: all_segments}}

      fixture ->
        with {:ok, %{segments: segments, entries: entries}} <- Fixtures.load(fixture) do
          load_type2_entries(entries)
          {:ok, %{kernels: [:fixture], segments: segments}}
        end
    end
  end

  @impl true
  def handle_call(:segments, _from, %{segments: segments} = state) do
    {:reply, segments, state}
  end

  # -----------------------------------------------------------------------
  # Kernel loading
  # -----------------------------------------------------------------------

  defp load_kernel(path) do
    with {:ok, daf} <- DAF.parse(path),
         {:ok, file} <- File.open(path, [:read, :binary]) do
      segments =
        daf.summaries
        |> Enum.map(&Segment.from_summary/1)
        |> Enum.filter(&(&1.data_type in [2, 21]))

      segments
      |> Enum.each(fn segment ->
        case segment.data_type do
          2 ->
            with {:ok, type2} <- Type2.parse_directory(file, segment, daf.endian),
                 {:ok, records} <- Type2.parse_all_records(file, segment, type2, daf.endian) do
              entry = %{segment: segment, data_type: 2, type2: type2, records: records}
              store_type2_entry(entry)
            else
              {:error, reason} ->
                Logger.warning(
                  "Skipping Type 2 segment (#{segment.target}→#{segment.center}): #{inspect(reason)}"
                )
            end

          21 ->
            with {:ok, type21} <- Type21.parse_directory(file, segment, daf.endian),
                 {:ok, records} <- Type21.parse_all_records(file, segment, type21, daf.endian) do
              entry = %{segment: segment, data_type: 21, type21: type21, records: records}
              store_type21_entry(entry)
            else
              {:error, reason} ->
                Logger.warning(
                  "Skipping Type 21 segment (#{segment.target}→#{segment.center}): #{inspect(reason)}"
                )
            end
        end
      end)

      File.close(file)
      {:ok, segments}
    end
  end

  # -----------------------------------------------------------------------
  # ETS storage
  # -----------------------------------------------------------------------

  defp store_type2_entry(%{segment: segment, data_type: 2, type2: type2, records: records}) do
    target = segment.target
    center = segment.center
    meta = %{segment: segment, data_type: 2, type2: type2}

    upsert_meta(target, center, meta)

    records
    |> Enum.with_index()
    |> Enum.each(fn {record, index} ->
      :ets.insert(@table, {{:record, target, center, index}, reversed_record(record)})
    end)
  end

  defp store_type21_entry(%{segment: segment, data_type: 21, type21: type21, records: records}) do
    target = segment.target
    center = segment.center
    seg_start = segment.start_addr
    meta = %{segment: segment, data_type: 21, type21: type21, seg_start: seg_start}

    upsert_meta(target, center, meta)

    records
    |> Enum.with_index()
    |> Enum.each(fn {record, index} ->
      :ets.insert(@table, {{:t21_record, target, center, seg_start, index}, record})
    end)
  end

  # Load pre-parsed Type 2 entries (used by the fixture path).
  defp load_type2_entries(entries) do
    entries
    |> Enum.group_by(fn %{segment: segment} -> {segment.target, segment.center} end)
    |> Enum.each(fn {{target, center}, grouped} ->
      metas =
        Enum.map(grouped, fn entry ->
          %{segment: entry.segment, data_type: 2, type2: entry.type2}
        end)

      existing = existing_metas(target, center)
      :ets.insert(@table, {{:meta, target, center}, existing ++ metas})

      Enum.each(grouped, fn %{records: records} ->
        records
        |> Enum.with_index()
        |> Enum.each(fn {record, index} ->
          :ets.insert(@table, {{:record, target, center, index}, reversed_record(record)})
        end)
      end)
    end)
  end

  # Store coefficients high-to-low so `Chebyshev.evaluate_reversed/2` can skip
  # the per-query `Enum.reverse/1` on the SPK hot path.
  defp reversed_record(record) do
    {record.mid, record.radius, Enum.reverse(record.coeff_x), Enum.reverse(record.coeff_y),
     Enum.reverse(record.coeff_z)}
  end

  defp upsert_meta(target, center, meta) do
    existing = existing_metas(target, center)
    :ets.insert(@table, {{:meta, target, center}, existing ++ [meta]})
  end

  defp existing_metas(target, center) do
    case :ets.lookup(@table, {:meta, target, center}) do
      [{_, metas}] -> metas
      [] -> []
    end
  end

  # -----------------------------------------------------------------------
  # Query dispatch
  # -----------------------------------------------------------------------

  defp find_meta(metas, epoch) do
    case Enum.find(metas, fn %{segment: segment} -> Segment.covers?(segment, epoch) end) do
      nil -> {:error, :segment_not_found}
      meta -> {:ok, meta}
    end
  end

  defp evaluate_at(target, center, %{data_type: 2, type2: type2}, epoch) do
    index = Type2.find_record_index(type2, epoch)

    case :ets.lookup(@table, {:record, target, center, index}) do
      [{_key, {mid, radius, cx, cy, cz}}] ->
        t = Chebyshev.normalize_time(epoch, mid, radius)
        x = Chebyshev.evaluate_reversed(cx, t)
        y = Chebyshev.evaluate_reversed(cy, t)
        z = Chebyshev.evaluate_reversed(cz, t)
        {:ok, {x, y, z}}

      [] ->
        {:error, :record_not_found}
    end
  end

  defp evaluate_at(target, center, %{data_type: 21, type21: type21, seg_start: seg_start}, epoch) do
    index = Type21.find_record_index(type21, epoch)

    case :ets.lookup(@table, {:t21_record, target, center, seg_start, index}) do
      [{_key, record}] ->
        case DifferenceArray.evaluate(record, epoch) do
          {:ok, {x, y, z, _vx, _vy, _vz}} -> {:ok, {x, y, z}}
          {:error, reason} -> {:error, reason}
        end

      [] ->
        {:error, :record_not_found}
    end
  end
end
