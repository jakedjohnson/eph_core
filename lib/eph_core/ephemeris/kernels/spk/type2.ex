defmodule EphCore.Ephemeris.Kernels.SPK.Type2 do
  @moduledoc """
  SPK Type 2 (Chebyshev position) parsing helpers.
  """

  alias EphCore.Ephemeris.Kernels.SPK.Segment

  defstruct [:init, :intlen, :rsize, :n]

  @type t :: %__MODULE__{
          init: float(),
          intlen: float(),
          rsize: integer(),
          n: integer()
        }

  @type record :: %{
          mid: float(),
          radius: float(),
          coeff_x: [float()],
          coeff_y: [float()],
          coeff_z: [float()]
        }

  @spec parse_directory(File.io_device(), Segment.t(), :little | :big) ::
          {:ok, t()} | {:error, term()}
  def parse_directory(file, %Segment{} = segment, endian) do
    offset = (segment.end_addr - 4) * 8

    with {:ok, data} <- :file.pread(file, offset, 32) do
      [init, intlen, rsize, n] = decode_doubles(data, endian)

      {:ok,
       %__MODULE__{
         init: init,
         intlen: intlen,
         rsize: round(rsize),
         n: round(n)
       }}
    end
  end

  @spec find_record_index(t(), float()) :: integer()
  def find_record_index(%__MODULE__{} = type2, epoch) do
    if type2.n <= 0 do
      0
    else
      index = trunc((epoch - type2.init) / type2.intlen)
      index |> max(0) |> min(type2.n - 1)
    end
  end

  @spec parse_record(File.io_device(), Segment.t(), t(), integer(), :little | :big) ::
          {:ok, record()} | {:error, term()}
  def parse_record(file, %Segment{} = segment, %__MODULE__{} = type2, index, endian) do
    record_bytes = type2.rsize * 8
    offset = (segment.start_addr - 1) * 8 + index * record_bytes

    with {:ok, data} <- :file.pread(file, offset, record_bytes) do
      doubles = decode_doubles(data, endian)
      {:ok, decode_record(doubles, type2.rsize)}
    end
  end

  @spec parse_all_records(File.io_device(), Segment.t(), t(), :little | :big) ::
          {:ok, [record()]} | {:error, term()}
  def parse_all_records(file, %Segment{} = segment, %__MODULE__{} = type2, endian) do
    if type2.n <= 0 do
      {:ok, []}
    else
      records =
        0..(type2.n - 1)
        |> Enum.map(fn index ->
          {:ok, record} = parse_record(file, segment, type2, index, endian)
          record
        end)

      {:ok, records}
    end
  end

  defp decode_record([mid, radius | coeffs], rsize) do
    coeff_count = div(rsize - 2, 3)
    {coeff_x, rest} = Enum.split(coeffs, coeff_count)
    {coeff_y, coeff_z} = Enum.split(rest, coeff_count)

    %{
      mid: mid,
      radius: radius,
      coeff_x: coeff_x,
      coeff_y: coeff_y,
      coeff_z: coeff_z
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
