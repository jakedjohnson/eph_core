defmodule EphCore.Ephemeris.Kernels.SPK.Type21 do
  @moduledoc """
  SPK Type 21 (Extended Modified Difference Arrays) segment parsing.

  Type 21 is the default format produced by JPL's Horizons system for small-body
  ephemerides. It uses Modified Difference Arrays (MDA) to represent trajectories,
  the same mathematical basis as Type 1 but with larger, higher-degree tables.

  ## Segment layout (DAF double addresses, 1-indexed)

    Record 0..N-1  (each DLSIZE doubles)
    Epoch table    (N doubles — final epoch of each record, TDB seconds past J2000)
    Epoch dir      (floor(N/100) doubles — every 100th epoch, for fast lookup)
    MAXDIM         (1 double — penultimate element; NOT DLSIZE despite NAIF docs)
    N              (1 double — last element)

  DLSIZE = 4 * MAXDIM + 11

  ## Record layout (0-indexed within record, M = MAXDIM)

    [0]        TL        — reference epoch (TDB seconds past J2000)
    [1..M]     G         — stepsize vector (M values)
    [M+1]      REFPOS_X
    [M+2]      REFVEL_X
    [M+3]      REFPOS_Y
    [M+4]      REFVEL_Y
    [M+5]      REFPOS_Z
    [M+6]      REFVEL_Z
    [M+7..4M+6]  DT      — difference table, 3×M column-major (X col, Y col, Z col)
    [4M+7]     KQMAX1    — max integration order + 1
    [4M+8]     KQ_X      — integration order for X
    [4M+9]     KQ_Y
    [4M+10]    KQ_Z
  """

  alias EphCore.Ephemeris.Kernels.SPK.Segment

  defstruct [:maxdim, :dlsize, :n, :epoch_table]

  @type t :: %__MODULE__{
          maxdim: integer(),
          dlsize: integer(),
          n: integer(),
          epoch_table: [float()]
        }

  @type record :: %{
          tl: float(),
          g: [float()],
          refpos: {float(), float(), float()},
          refvel: {float(), float(), float()},
          dt: {[float()], [float()], [float()]},
          kqmax1: integer(),
          kq: {integer(), integer(), integer()}
        }

  @spec parse_directory(File.io_device(), Segment.t(), :little | :big) ::
          {:ok, t()} | {:error, term()}
  def parse_directory(file, %Segment{} = segment, endian) do
    maxdim_offset = (segment.end_addr - 2) * 8
    n_offset = (segment.end_addr - 1) * 8

    with {:ok, maxdim_data} <- :file.pread(file, maxdim_offset, 8),
         {:ok, n_data} <- :file.pread(file, n_offset, 8) do
      [maxdim_f] = decode_doubles(maxdim_data, endian)
      [n_f] = decode_doubles(n_data, endian)

      maxdim = round(maxdim_f)
      n = round(n_f)
      dlsize = 4 * maxdim + 11

      epoch_table_offset = (segment.start_addr - 1 + n * dlsize) * 8

      with {:ok, epoch_data} <- :file.pread(file, epoch_table_offset, n * 8) do
        epoch_table = decode_doubles(epoch_data, endian)

        {:ok,
         %__MODULE__{
           maxdim: maxdim,
           dlsize: dlsize,
           n: n,
           epoch_table: epoch_table
         }}
      end
    end
  end

  @doc """
  Find the 0-based index of the record that covers `epoch`.

  Returns the index of the first record whose final epoch is strictly greater
  than the query epoch. Falls back to the last record if epoch is at or past
  the last final epoch (matches spktype21 Python behavior).
  """
  @spec find_record_index(t(), float()) :: integer()
  def find_record_index(%__MODULE__{epoch_table: epoch_table, n: n}, epoch) do
    case Enum.find_index(epoch_table, fn e -> e > epoch end) do
      nil -> n - 1
      idx -> idx
    end
  end

  @spec parse_record(File.io_device(), Segment.t(), t(), integer(), :little | :big) ::
          {:ok, record()} | {:error, term()}
  def parse_record(file, %Segment{} = segment, %__MODULE__{} = type21, index, endian) do
    offset = (segment.start_addr - 1 + index * type21.dlsize) * 8
    size = type21.dlsize * 8

    with {:ok, data} <- :file.pread(file, offset, size) do
      doubles = decode_doubles(data, endian)
      {:ok, decode_record(doubles, type21.maxdim)}
    end
  end

  @spec parse_all_records(File.io_device(), Segment.t(), t(), :little | :big) ::
          {:ok, [record()]} | {:error, term()}
  def parse_all_records(file, %Segment{} = segment, %__MODULE__{} = type21, endian) do
    if type21.n <= 0 do
      {:ok, []}
    else
      records =
        Enum.map(0..(type21.n - 1), fn index ->
          {:ok, record} = parse_record(file, segment, type21, index, endian)
          record
        end)

      {:ok, records}
    end
  end

  # -----------------------------------------------------------------------
  # Private helpers
  # -----------------------------------------------------------------------

  defp decode_record(doubles, maxdim) do
    tl = Enum.at(doubles, 0)
    g = Enum.slice(doubles, 1, maxdim)

    refpos_x = Enum.at(doubles, maxdim + 1)
    refvel_x = Enum.at(doubles, maxdim + 2)
    refpos_y = Enum.at(doubles, maxdim + 3)
    refvel_y = Enum.at(doubles, maxdim + 4)
    refpos_z = Enum.at(doubles, maxdim + 5)
    refvel_z = Enum.at(doubles, maxdim + 6)

    # DT table: 3*MAXDIM values, stored column-major: X col, Y col, Z col.
    # DT[j, component] where j is order index (0-based), component is 0/1/2.
    dt_flat = Enum.slice(doubles, maxdim + 7, 3 * maxdim)
    dt_x = Enum.slice(dt_flat, 0, maxdim)
    dt_y = Enum.slice(dt_flat, maxdim, maxdim)
    dt_z = Enum.slice(dt_flat, 2 * maxdim, maxdim)

    kqmax1 = round(Enum.at(doubles, 4 * maxdim + 7))
    kq_x = round(Enum.at(doubles, 4 * maxdim + 8))
    kq_y = round(Enum.at(doubles, 4 * maxdim + 9))
    kq_z = round(Enum.at(doubles, 4 * maxdim + 10))

    %{
      tl: tl,
      g: g,
      refpos: {refpos_x, refpos_y, refpos_z},
      refvel: {refvel_x, refvel_y, refvel_z},
      dt: {dt_x, dt_y, dt_z},
      kqmax1: kqmax1,
      kq: {kq_x, kq_y, kq_z}
    }
  end

  defp decode_doubles(data, :little) do
    for <<chunk::binary-size(8) <- data>> do
      <<value::float-little>> = chunk
      value
    end
  end

  defp decode_doubles(data, :big) do
    for <<chunk::binary-size(8) <- data>> do
      <<value::float-big>> = chunk
      value
    end
  end
end
