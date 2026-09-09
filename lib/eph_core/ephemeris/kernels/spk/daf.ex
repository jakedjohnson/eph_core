defmodule EphCore.Ephemeris.Kernels.SPK.DAF do
  @moduledoc """
  DAF binary container parsing for SPK files.
  """

  @record_bytes 1024

  defstruct [
    :path,
    :nd,
    :ni,
    :forward,
    :backward,
    :free,
    :endian,
    :summaries
  ]

  @type t :: %__MODULE__{
          path: String.t(),
          nd: non_neg_integer(),
          ni: non_neg_integer(),
          forward: non_neg_integer(),
          backward: non_neg_integer(),
          free: non_neg_integer(),
          endian: :little | :big,
          summaries: [summary()]
        }

  @type summary :: %{double: [float()], int: [integer()]}

  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(path) when is_binary(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          with {:ok, header} <- :file.pread(file, 0, @record_bytes),
               {:ok, fields} <- parse_header(header),
               {:ok, endian} <- detect_endian(file, fields.forward, fields.nd, fields.ni),
               {:ok, summaries} <- read_summaries(file, fields, endian) do
            {:ok,
             %__MODULE__{
               path: path,
               nd: fields.nd,
               ni: fields.ni,
               forward: fields.forward,
               backward: fields.backward,
               free: fields.free,
               endian: endian,
               summaries: summaries
             }}
          else
            {:error, reason} -> {:error, reason}
          end
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec read_summaries(t()) :: [summary()]
  def read_summaries(%__MODULE__{} = daf) do
    with {:ok, file} <- File.open(daf.path, [:read, :binary]),
         {:ok, summaries} <- read_summaries(file, daf, daf.endian) do
      File.close(file)
      summaries
    else
      _ -> []
    end
  end

  defp parse_header(header) do
    case parse_header_ascii(header) do
      {:ok, fields} -> {:ok, fields}
      {:error, _} -> parse_header_binary(header)
    end
  end

  defp parse_header_ascii(
         <<id::binary-size(8), nd_field::binary-size(8), ni_field::binary-size(8),
           _internal_name::binary-size(60), forward_field::binary-size(8),
           backward_field::binary-size(8), free_field::binary-size(8), _rest::binary>>
       ) do
    if String.starts_with?(id, "DAF/SPK") do
      with {:ok, nd} <- parse_int_field(nd_field),
           {:ok, ni} <- parse_int_field(ni_field),
           {:ok, forward} <- parse_int_field(forward_field),
           {:ok, backward} <- parse_int_field(backward_field),
           {:ok, free} <- parse_int_field(free_field) do
        {:ok, %{nd: nd, ni: ni, forward: forward, backward: backward, free: free}}
      else
        _ -> {:error, :invalid_header}
      end
    else
      {:error, :invalid_daf_id}
    end
  end

  defp parse_header_ascii(_), do: {:error, :invalid_header}

  defp parse_header_binary(<<id::binary-size(8), _rest::binary>> = header) do
    if String.starts_with?(id, "DAF/SPK") and byte_size(header) >= 96 do
      format = binary_part(header, 88, 8)

      endian =
        case format do
          "BIG-IEEE" -> :big
          _ -> :little
        end

      parse_binary_fields(header, endian)
    else
      {:error, :invalid_daf_id}
    end
  end

  defp parse_header_binary(_), do: {:error, :invalid_header}

  defp parse_binary_fields(
         <<_id::binary-size(8), nd::little-unsigned-32, ni::little-unsigned-32,
           _internal_name::binary-size(60), forward::little-unsigned-32,
           backward::little-unsigned-32, free::little-unsigned-32, _format::binary-size(8),
           _rest::binary>>,
         :little
       ) do
    {:ok, %{nd: nd, ni: ni, forward: forward, backward: backward, free: free}}
  end

  defp parse_binary_fields(
         <<_id::binary-size(8), nd::big-unsigned-32, ni::big-unsigned-32,
           _internal_name::binary-size(60), forward::big-unsigned-32, backward::big-unsigned-32,
           free::big-unsigned-32, _format::binary-size(8), _rest::binary>>,
         :big
       ) do
    {:ok, %{nd: nd, ni: ni, forward: forward, backward: backward, free: free}}
  end

  defp parse_binary_fields(_, _), do: {:error, :invalid_header}

  defp parse_int_field(field) do
    trimmed = String.trim(field)

    case Integer.parse(trimmed) do
      {value, ""} -> {:ok, value}
      _ -> {:error, :invalid_integer_field}
    end
  end

  defp detect_endian(_file, 0, _nd, _ni), do: {:ok, :little}

  defp detect_endian(file, record, nd, ni) do
    offset = (record - 1) * @record_bytes

    with {:ok, data} <- :file.pread(file, offset, @record_bytes) do
      {:ok, choose_endian(data, nd, ni)}
    end
  end

  defp choose_endian(data, nd, ni) do
    case parse_summary_header(data, :little, nd, ni) do
      {:ok, _} -> :little
      {:error, _} -> :big
    end
  end

  defp read_summaries(file, %{nd: nd, ni: ni, forward: forward}, endian) do
    summary_size = nd + div(ni + 1, 2)
    read_summary_records(file, forward, nd, ni, summary_size, endian, [])
  end

  defp read_summary_records(_file, 0, _nd, _ni, _summary_size, _endian, acc),
    do: {:ok, Enum.reverse(acc)}

  defp read_summary_records(file, record, nd, ni, summary_size, endian, acc) do
    offset = (record - 1) * @record_bytes

    with {:ok, data} <- :file.pread(file, offset, @record_bytes),
         {:ok, %{next: next, nsum: nsum}} <- parse_summary_header(data, endian, nd, ni) do
      summaries =
        data
        |> summary_chunks()
        |> parse_summaries(nsum, summary_size, nd, ni, endian)

      read_summary_records(file, next, nd, ni, summary_size, endian, summaries ++ acc)
    end
  end

  defp parse_summary_header(data, endian, nd, ni) do
    summary_size = nd + div(ni + 1, 2)

    with [next, prev, nsum | _rest] <- decode_doubles(data, 3, endian),
         true <- valid_summary_header?(next, prev, nsum, summary_size) do
      {:ok, %{next: round(next), prev: round(prev), nsum: round(nsum)}}
    else
      _ -> {:error, :invalid_summary_header}
    end
  end

  defp valid_summary_header?(next, prev, nsum, summary_size) do
    Enum.all?([next, prev, nsum], &integerish?/1) and
      next >= 0 and prev >= 0 and nsum >= 0 and nsum <= max_summaries(summary_size)
  end

  defp integerish?(value), do: abs(value - Float.round(value)) < 1.0e-6

  defp max_summaries(summary_size) do
    div(125, summary_size)
  end

  defp summary_chunks(data) do
    <<_header::binary-size(24), rest::binary>> = data
    for <<chunk::binary-size(8) <- rest>>, do: chunk
  end

  defp parse_summaries(chunks, nsum, summary_size, nd, ni, endian) do
    if nsum == 0 do
      []
    else
      for i <- 0..(nsum - 1) do
        start = i * summary_size
        summary_chunks = Enum.slice(chunks, start, summary_size)
        decode_summary(summary_chunks, nd, ni, endian)
      end
    end
  end

  defp decode_summary(summary_chunks, nd, ni, endian) do
    {double_chunks, int_chunks} = Enum.split(summary_chunks, nd)

    doubles =
      double_chunks
      |> Enum.map(&decode_float64(&1, endian))

    ints =
      int_chunks
      |> Enum.flat_map(&decode_int32_pair(&1, endian))
      |> Enum.take(ni)

    %{double: doubles, int: ints}
  end

  defp decode_doubles(data, count, endian) do
    slice = binary_part(data, 0, count * 8)
    for <<chunk::binary-size(8) <- slice>>, do: decode_float64(chunk, endian)
  end

  defp decode_float64(<<value::float-little>>, :little), do: value
  defp decode_float64(<<value::float-big>>, :big), do: value

  defp decode_int32_pair(chunk, :little) do
    <<a::little-signed-32, b::little-signed-32>> = chunk
    [a, b]
  end

  defp decode_int32_pair(chunk, :big) do
    <<a::big-signed-32, b::big-signed-32>> = chunk
    [a, b]
  end
end
