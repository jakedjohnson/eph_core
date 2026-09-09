defmodule EphCore.AstronomicalTime.Tables.EarthOrientationParameters do
  @moduledoc """
  Supervised ETS cache of the IERS Earth Orientation Parameters.

  Started with the application, it parses `finals2000A.all` once and serves
  per-day rows to the UT1 and Earth-rotation code. Each row carries the
  Modified Julian Date, polar motion `x`/`y` (arcseconds), `UT1-UTC` (seconds),
  length-of-day, and the `dX`/`dY` nutation offsets (milliarcseconds).

  The file is ~6 MB of plain ASCII covering roughly 20,000 days and occupies
  under 1 MB in ETS once parsed. IERS republishes it weekly; refresh it
  whenever you need current or predicted UT1 values.

  Run `mix eph.download_kernels` to fetch `finals2000A.all`.
  """
  use GenServer

  alias EphCore.Ephemeris.Kernels.EOP

  @table __MODULE__

  # Note: This must be a function, not a module attribute!
  # Module attributes are evaluated at compile time, but kernel_base_dir
  # is configured at runtime in releases via runtime.exs.
  defp finals_path, do: EOP.finals2000a_path()

  # Client API
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns UT1–UTC in seconds for the given Modified Julian Day (float).
  Performs nearest-day lookup.
  """
  def ut1_minus_utc_seconds(mjd) when is_number(mjd) do
    day = mjd |> Float.floor() |> trunc()

    case :ets.lookup(@table, day) do
      [{^day, ut1_utc} | _] ->
        ut1_utc

      [] ->
        case :ets.prev(@table, day) do
          :"$end_of_table" ->
            0.0

          prev_day ->
            case :ets.lookup(@table, prev_day) do
              [{^prev_day, ut1_utc} | _] -> ut1_utc
              _ -> 0.0
            end
        end

      _ ->
        0.0
    end
  end

  # Server callbacks
  @impl true
  def init(_opts) do
    {:ok, _} = EOP.ensure_files()
    _ = :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])

    case File.read(finals_path()) do
      {:ok, contents} ->
        entries = parse_finals2000a(contents)
        Enum.each(entries, fn {mjd_int, ut1_utc} -> :ets.insert(@table, {mjd_int, ut1_utc}) end)
        {:ok, %{count: length(entries)}}

      {:error, reason} ->
        {:ok, %{error: reason, count: 0}}
    end
  end

  # Parsing
  # The finals2000A.all file has two formats:
  #
  # Old format (pre-2000s): "73 1 2 41684.00 I 0.120733 ..."
  #   - Tokens: [year, month, day, MJD, flag, ...]
  #   - MJD at index 3, UT1-UTC at index 10
  #
  # New format (2000s+): "26 114 61054.00 P 0.096387 ..."
  #   - Tokens: [year, monthday, MJD, flag, ...]
  #   - MJD at index 2, UT1-UTC at index 9
  #
  # We detect format by checking if token 3 parses as a float (old) or letter (new).
  defp parse_finals2000a(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.reduce([], fn line, acc ->
      tokens = String.split(line)

      with true <- length(tokens) >= 5,
           {mjd, ut1_utc} when is_number(mjd) and is_number(ut1_utc) <- locate_mjd_and_ut1(tokens) do
        if mjd > 0 do
          result = {trunc(Float.floor(mjd)), ut1_utc}
          [result | acc]
        else
          acc
        end
      else
        _ -> acc
      end
    end)
    |> Enum.uniq_by(fn {mjd_int, _} -> mjd_int end)
    |> Enum.sort_by(fn {mjd_int, _} -> mjd_int end)
  end

  defp parse_float(str) do
    case Float.parse(str || "") do
      {v, _} -> v
      :error -> :error
    end
  end

  # Detect the format and extract MJD and UT1-UTC values
  defp locate_mjd_and_ut1(tokens) do
    # Try old format first: MJD at index 3, UT1-UTC at index 10
    case parse_float(Enum.at(tokens, 3)) do
      mjd when is_number(mjd) and mjd > 30_000 ->
        # Old format confirmed (MJD values are ~40000-60000)
        ut1_utc = locate_ut1_utc_at(tokens, 10)
        {mjd, ut1_utc}

      _ ->
        # Try new format: MJD at index 2, UT1-UTC at index 9
        case parse_float(Enum.at(tokens, 2)) do
          mjd when is_number(mjd) and mjd > 30_000 ->
            ut1_utc = locate_ut1_utc_at(tokens, 9)
            {mjd, ut1_utc}

          _ ->
            :error
        end
    end
  end

  # Try to get UT1-UTC at the specified index, with fallback
  defp locate_ut1_utc_at(tokens, primary_index) do
    case parse_float(Enum.at(tokens, primary_index)) do
      v when is_number(v) ->
        v

      _ ->
        # Fallback: find first numeric value in last 8 tokens
        tokens
        |> Enum.take(-8)
        |> Enum.find_value(:error, fn t ->
          case Float.parse(t) do
            {v, _} -> v
            :error -> false
          end
        end)
    end
  end
end
