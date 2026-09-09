defmodule EphCore.Stars.Catalog do
  @moduledoc """
  Hipparcos star catalog loader and lookup.

  Parses `stars/hip_main.dat` under the configured kernel base directory on first
  use and caches the result in `:persistent_term` for fast read-heavy access.

  Rows with blank RA, Dec, or Vmag are skipped (incomplete Hipparcos solutions);
  they are never stored as phantom `(0°, 0°)` positions.
  """

  alias EphCore.Ephemeris.Kernels

  @persistent_term_key :eph_core_stars_catalog

  @significance_list %{
    49_669 => "Regulus",
    21_421 => "Aldebaran",
    80_763 => "Antares",
    113_368 => "Fomalhaut",
    32_349 => "Sirius",
    14_576 => "Algol",
    65_474 => "Spica",
    91_262 => "Vega",
    69_673 => "Arcturus"
  }

  @type star_record :: %{
          hip: integer(),
          name: String.t() | nil,
          ra_deg: float(),
          dec_deg: float(),
          pm_ra_mas_yr: float(),
          pm_dec_mas_yr: float(),
          parallax_mas: float(),
          magnitude: float()
        }

  @doc """
  Returns the configured HIP → traditional name map for significant stars.
  """
  @spec significance_list() :: %{integer() => String.t()}
  def significance_list, do: @significance_list

  @doc """
  Looks up a star by Hipparcos number.

  Returns `{:ok, star_record}` or `{:error, :not_found}`.
  """
  @spec lookup(integer()) :: {:ok, star_record()} | {:error, :not_found}
  def lookup(hip) when is_integer(hip) do
    case ensure_loaded()[hip] do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @doc """
  Returns every valid parsed star record (incomplete catalog rows excluded).
  """
  @spec all() :: [star_record()]
  def all do
    ensure_loaded()
    |> Map.values()
  end

  @doc """
  Returns star records for all configured significant stars that exist in the catalog.
  """
  @spec all_significant() :: [star_record()]
  def all_significant do
    catalog = ensure_loaded()

    @significance_list
    |> Map.keys()
    |> Enum.sort()
    |> Enum.flat_map(fn hip ->
      case catalog[hip] do
        nil -> []
        record -> [record]
      end
    end)
  end

  defp ensure_loaded do
    case :persistent_term.get(@persistent_term_key, :not_loaded) do
      :not_loaded ->
        catalog = load_catalog()
        :persistent_term.put(@persistent_term_key, catalog)
        catalog

      catalog ->
        catalog
    end
  end

  defp load_catalog do
    path = Kernels.stars_path("hip_main.dat")

    path
    |> File.stream!([], :line)
    |> Enum.reduce(%{}, &parse_line/2)
  end

  defp parse_line(line, acc) do
    fields = String.split(line, "|")

    with [_, hip_field | _] <- fields,
         {:ok, hip} <- parse_int(String.trim(hip_field)),
         {:ok, record} <- build_record(hip, fields) do
      Map.put(acc, hip, record)
    else
      _ -> acc
    end
  end

  defp build_record(hip, fields) do
    with {:ok, ra_deg} <- required_float(fields, 8),
         {:ok, dec_deg} <- required_float(fields, 9),
         {:ok, magnitude} <- required_float(fields, 5) do
      {:ok,
       %{
         hip: hip,
         name: Map.get(@significance_list, hip),
         ra_deg: ra_deg,
         dec_deg: dec_deg,
         # hip_main.dat column order: 11 = Plx (parallax), 12 = pmRA, 13 = pmDE.
         pm_ra_mas_yr: optional_float(fields, 12),
         pm_dec_mas_yr: optional_float(fields, 13),
         parallax_mas: optional_float(fields, 11),
         magnitude: magnitude
       }}
    end
  end

  defp required_float(fields, index) do
    fields
    |> Enum.at(index, "")
    |> String.trim()
    |> case do
      "" -> :error
      value -> parse_float_value(value)
    end
  end

  defp optional_float(fields, index) do
    fields
    |> Enum.at(index, "")
    |> String.trim()
    |> case do
      "" ->
        0.0

      value ->
        case parse_float_value(value) do
          {:ok, f} -> f
          :error -> 0.0
        end
    end
  end

  defp parse_float_value(value) do
    case Float.parse(value) do
      {f, _} -> {:ok, f}
      :error -> :error
    end
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, _} -> {:ok, int}
      :error -> :error
    end
  end
end
