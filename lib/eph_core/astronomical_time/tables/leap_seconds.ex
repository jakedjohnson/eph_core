defmodule EphCore.AstronomicalTime.Tables.LeapSeconds do
  @moduledoc """
  Supervised ETS cache of the UTC ↔ TAI leap-second table.

  Started with the application, it parses the SPICE leap-seconds kernel
  `naif0012.tls` (or Skyfield's `tai-utc.dat`) once and serves the offset for a
  given UTC timestamp to `EphCore.AstronomicalTime.InternationalAtomicTime`.
  Both files are small ASCII tables listing every offset boundary since 1972;
  IERS announces new leap seconds about six months in advance, so refreshing
  the file is a rare, out-of-band task.

  Timestamps before 1972 use a zero offset, following
  [Skyfield issue #679](https://github.com/skyfielders/python-skyfield/issues/679).

  Run `mix eph.download_kernels` to fetch `naif0012.tls`.
  """
  use GenServer

  alias EphCore.Ephemeris.Kernels.LSK

  @table __MODULE__
  @micros_per_second 1_000_000

  # Note: These must be functions, not module attributes!
  # Module attributes are evaluated at compile time, but kernel_base_dir
  # is configured at runtime in releases via runtime.exs.
  defp lsk_naif_path, do: LSK.naif_path()
  defp lsk_skyfield_path, do: LSK.skyfield_path()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the leap offset in microseconds for the given UTC timestamp.
  Accepts either a DateTime in UTC or an integer unix microseconds.
  """
  def offset_at(utc_datetime_microseconds) when is_integer(utc_datetime_microseconds) do
    case lookup_offset_seconds(utc_datetime_microseconds) do
      nil -> 0
      seconds when is_integer(seconds) -> seconds * @micros_per_second
    end
  end

  def offset_at(%DateTime{time_zone: "Etc/UTC"} = dt) do
    micros = DateTime.to_unix(dt, :microsecond)
    offset_at(micros)
  end

  def offset_at(%DateTime{} = dt) do
    {:ok, utc} = DateTime.shift_zone(dt, "Etc/UTC")
    offset_at(utc)
  end

  # Server callbacks
  @impl true
  def init(_opts) do
    {:ok, _} = LSK.ensure_files()
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    _ = table

    {:ok, state} = do_load()

    state = maybe_schedule_reload(state)
    {:ok, state}
  end

  # Internal helpers
  defp lookup_offset_seconds(utc_microseconds) do
    # We store entries keyed by effective microseconds; find the last effective <= input
    case :ets.lookup(@table, :__index__) do
      [{:__index__, keys}] when is_list(keys) ->
        target = utc_microseconds

        {_k, seconds} =
          keys
          |> Enum.take_while(fn k -> k <= target end)
          |> List.last()
          |> case do
            nil -> {nil, 0}
            k -> List.first(:ets.lookup(@table, k))
          end

        seconds

      _ ->
        0
    end
  end

  defp load_entries(entries) do
    # entries: list of {effective_microseconds, offset_seconds}
    Enum.each(entries, fn {eff_us, offset_s} ->
      :ets.insert(@table, {eff_us, offset_s})
    end)

    sorted_keys = entries |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    :ets.insert(@table, {:__index__, sorted_keys})
  end

  defp do_load do
    # Prefer Skyfield/USNO (smaller, simpler), fallback to NAIF
    case File.read(lsk_skyfield_path()) do
      {:ok, contents} ->
        case parse_skyfield(contents) do
          {:ok, entries} when entries != [] ->
            :ets.delete_all_objects(@table)
            load_entries(entries)
            {:ok, %{count: length(entries), source: :skyfield}}

          _ ->
            load_from_naif()
        end

      _ ->
        load_from_naif()
    end
  end

  defp load_from_naif do
    case File.read(lsk_naif_path()) do
      {:ok, contents} ->
        entries = parse_naif_lsk(contents)
        :ets.delete_all_objects(@table)
        load_entries(entries)
        {:ok, %{count: length(entries), source: :naif}}

      {:error, reason} ->
        {:ok, %{error: reason, count: 0}}
    end
  end

  @reload_message :__reload_lsk__

  defp maybe_schedule_reload(state) do
    interval_ms = Application.get_env(:eph_core, :leap_seconds_reload_ms, nil)

    if is_integer(interval_ms) and interval_ms > 0 do
      Process.send_after(self(), @reload_message, interval_ms)
      Map.put(state, :reload_ms, interval_ms)
    else
      state
    end
  end

  @impl true
  def handle_info(@reload_message, _state) do
    {:ok, state} = do_load()
    state = maybe_schedule_reload(state)
    {:noreply, state}
  end

  @doc """
  Force reload leap seconds table from disk.
  """
  def reload! do
    GenServer.call(__MODULE__, :reload)
  end

  @impl true
  def handle_call(:reload, _from, _state) do
    {:ok, state} = do_load()
    {:reply, :ok, state}
  end

  defp parse_naif_lsk(contents) when is_binary(contents) do
    # Extract the DELTET/DELTA_AT block and parse pairs like:
    #  10,   @1972-JAN-1
    # into {~U[1972-01-01 00:00:00Z], 10}
    block =
      contents
      |> String.split("\n")
      |> extract_delta_at_lines([])
      |> Enum.reverse()

    block
    |> Enum.map(&parse_delta_at_line/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {eff_us, _} -> eff_us end)
  end

  defp parse_skyfield(contents) when is_binary(contents) do
    # USNO format example:
    # "1972 JAN  1 =JD 2441317.5  TAI-UTC=  10.0       S + (MJD - 41317.) X 0.0      S"
    lines =
      contents
      |> String.split("\n", trim: true)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reject(&String.starts_with?(&1, "#"))

    entries =
      lines
      |> Enum.reduce([], fn line, acc ->
        case Regex.run(
               ~r/^\s*(\d{4})\s+([A-Z]{3})\s+(\d{1,2}).*?TAI-UTC=\s*([0-9]+(?:\.[0-9]+)?)\s*S.*?X\s*([0-9.]+)\s*S/i,
               line
             ) do
          [_, y, mon3, d, sec_str, slope_str] ->
            with {slope, _} <- Float.parse(slope_str),
                 true <- slope == 0.0,
                 {:ok, month} <- month3_to_int(String.upcase(mon3)),
                 {day, ""} <- Integer.parse(d),
                 {:ok, date} <- Date.new(String.to_integer(y), month, day),
                 {:ok, dt} <- DateTime.new(date, ~T[00:00:00], "Etc/UTC"),
                 {sec_float, _} <- Float.parse(sec_str) do
              eff = DateTime.to_unix(dt, :microsecond)
              [{eff, trunc(sec_float)} | acc]
            else
              _ -> acc
            end

          _ ->
            acc
        end
      end)
      |> Enum.uniq()
      |> Enum.sort_by(&elem(&1, 0))

    {:ok, entries}
  end

  defp extract_delta_at_lines(["DELTET/DELTA_AT" <> _ = line | rest], acc) do
    extract_delta_at_block([line | rest], acc)
  end

  defp extract_delta_at_lines([_ | rest], acc), do: extract_delta_at_lines(rest, acc)
  defp extract_delta_at_lines([], acc), do: acc

  defp extract_delta_at_block([line | rest], acc) do
    if String.contains?(line, ")") do
      # Closing line may contain last entry and ")"
      items = line |> String.replace(~r/.*=\s*\(|\)/, "") |> String.trim()
      acc = if items == "", do: acc, else: [items | acc]
      acc
    else
      items = line |> String.replace(~r/.*=\s*\(|\)/, "") |> String.trim()
      acc = if items == "", do: acc, else: [items | acc]
      extract_delta_at_block(rest, acc)
    end
  end

  defp parse_delta_at_line(line) do
    # Each line in the NAIF LSK is a single entry: "10,   @1972-JAN-1"
    # Parse directly without splitting (the comma is part of the format)
    parse_entry(String.trim(line))
  end

  defp parse_entry(entry) do
    # Match format: "SECONDS,   @YYYY-MON-DD" (with flexible whitespace)
    case Regex.run(~r/^(\d+),\s*@([0-9]{4})-([A-Z]{3})-(\d{1,2})$/, entry) do
      [_, sec_str, year, mon3, day_str] ->
        with {sec, ""} <- Integer.parse(sec_str),
             {day, ""} <- Integer.parse(day_str),
             {:ok, month} <- month3_to_int(mon3),
             {:ok, dt} <- Date.new(String.to_integer(year), month, day),
             {:ok, dtm} <- DateTime.new(dt, ~T[00:00:00], "Etc/UTC") do
          {DateTime.to_unix(dtm, :microsecond), sec}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp month3_to_int(mon3) do
    case mon3 do
      "JAN" -> {:ok, 1}
      "FEB" -> {:ok, 2}
      "MAR" -> {:ok, 3}
      "APR" -> {:ok, 4}
      "MAY" -> {:ok, 5}
      "JUN" -> {:ok, 6}
      "JUL" -> {:ok, 7}
      "AUG" -> {:ok, 8}
      "SEP" -> {:ok, 9}
      "OCT" -> {:ok, 10}
      "NOV" -> {:ok, 11}
      "DEC" -> {:ok, 12}
      _ -> :error
    end
  end
end
