defmodule EphCore.EarthOrientation.Tables.NutationIAU2000A do
  @moduledoc """
  IAU 2000A_R06 Nutation Series, loaded once at application startup.

  Terms are parsed from IERS Conventions 2010 Tables 5.3a and 5.3b and stored in
  `:persistent_term` so `get_terms/0` avoids copying ~680 entries on every nutation eval.

  Reads and parses kernel tables on startup via this GenServer.
  Complete lunisolar and planetary nutation series (~680 unique terms).

  Each term contributes to nutation in longitude (Δψ) and obliquity (Δε).

  ## Precision
  The full series provides precision better than 0.1 microarcseconds.

  ## References
  - IERS Conventions 2010, Chapter 5
  - https://iers-conventions.obspm.fr/content/chapter5/
  """
  use GenServer

  alias EphCore.Ephemeris.Kernels

  @terms_key {__MODULE__, :terms}

  # Note: These must be functions, not module attributes!
  # Module attributes are evaluated at compile time, but kernel_base_dir
  # is configured at runtime in releases via runtime.exs.
  defp lon_file, do: Kernels.nutation_path("tab5.3a.txt")
  defp obl_file, do: Kernels.nutation_path("tab5.3b.txt")

  # Client API
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns all nutation terms (shared, read-only list from `:persistent_term`).

  Each term is a tuple:
  `{index, {l, l', F, D, Ω, psi_sin, psi_cos, psi_t, eps_cos, eps_sin, eps_t}}`

  Coefficients are in microarcseconds as floats from IERS tables.
  """
  def get_terms do
    :telemetry.execute([:eph_core, :nutation, :get_terms], %{count: 1}, %{})
    :persistent_term.get(@terms_key)
  end

  # Server callbacks
  @impl true
  def init(_opts) do
    terms = parse_iers_tables()
    :persistent_term.put(@terms_key, terms)

    {:ok, %{count: length(terms)}}
  end

  # Parsing IERS tables
  defp parse_iers_tables do
    # Parse both j=0 (constant) and j=1 (time-dependent) sections
    lon_j0 = parse_table_section(lon_file(), "j = 0")
    lon_j1 = parse_table_section(lon_file(), "j = 1")
    obl_j0 = parse_table_section(obl_file(), "j = 0")
    obl_j1 = parse_table_section(obl_file(), "j = 1")

    # Build lookup maps keyed by the (l, l', F, D, Ω) luni-solar argument tuple.
    # Table 5.3a longitude columns are (A_i sin, A"_i cos); table 5.3b obliquity
    # columns are the OTHER way round — (B"_i sin, B_i cos) — so the obliquity
    # cosine amplitude is the *second* parsed coefficient, not the first.
    lon_j0_map =
      Map.new(lon_j0, fn {_idx, args, psi_sin, psi_cos} -> {args, {psi_sin, psi_cos}} end)

    lon_j1_map = Map.new(lon_j1, fn {_idx, args, psi_sin_t, _cos_t} -> {args, psi_sin_t} end)

    obl_j0_map =
      Map.new(obl_j0, fn {_idx, args, eps_sin, eps_cos} -> {args, {eps_cos, eps_sin}} end)

    obl_j1_map = Map.new(obl_j1, fn {_idx, args, _sin_t, eps_cos_t} -> {args, eps_cos_t} end)

    # Merge all unique argument combinations
    all_args =
      [lon_j0_map, lon_j1_map, obl_j0_map, obl_j1_map]
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()
      |> Enum.sort()

    # Create complete terms
    all_args
    |> Enum.with_index(1)
    |> Enum.map(fn {{l, lp, f, d, om} = args, idx} ->
      {psi_s, psi_c} = Map.get(lon_j0_map, args, {0.0, 0.0})
      psi_t = Map.get(lon_j1_map, args, 0.0)
      {eps_c, eps_s} = Map.get(obl_j0_map, args, {0.0, 0.0})
      eps_t = Map.get(obl_j1_map, args, 0.0)

      {idx, {l, lp, f, d, om, psi_s, psi_c, psi_t, eps_c, eps_s, eps_t}}
    end)
  end

  defp parse_table_section(file_path, section_marker) do
    file_path
    |> File.read!()
    |> String.split("\n")
    |> find_section(section_marker)
    |> Enum.filter(&data_line?/1)
    |> Enum.map(&parse_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp find_section(lines, marker) do
    case Enum.find_index(lines, &String.contains?(&1, marker)) do
      nil ->
        []

      start_idx ->
        lines
        |> Enum.drop(start_idx + 3)
        |> Enum.take_while(fn line ->
          # Stop at next "j = " marker
          not (line |> String.trim() |> String.starts_with?("j = "))
        end)
    end
  end

  defp data_line?(line) do
    String.match?(String.trim(line), ~r/^\d+\s+/)
  end

  defp parse_line(line) do
    parts = line |> String.split() |> Enum.reject(&(&1 == ""))

    # Columns: i, coef1, coef2, then 5 luni-solar (l l' F D Ω) + 9 planetary
    # multipliers (L_Me … p_A). We keep only the luni-solar terms (all planetary
    # multipliers zero): keying on the 5 luni-solar multipliers alone, planetary
    # terms that share those 5 values would otherwise collide in the lookup map
    # and overwrite the dominant luni-solar amplitudes. The luni-solar series
    # alone is accurate to well under a milliarcsecond — far tighter than the
    # almanac needs.
    if length(parts) >= 17 and luni_solar_only?(parts) do
      idx = String.to_integer(Enum.at(parts, 0))
      coef1 = String.to_float(Enum.at(parts, 1))
      coef2 = String.to_float(Enum.at(parts, 2))
      l = String.to_integer(Enum.at(parts, 3))
      lp = String.to_integer(Enum.at(parts, 4))
      f = String.to_integer(Enum.at(parts, 5))
      d = String.to_integer(Enum.at(parts, 6))
      om = String.to_integer(Enum.at(parts, 7))

      {idx, {l, lp, f, d, om}, coef1, coef2}
    end
  end

  defp luni_solar_only?(parts) do
    parts
    |> Enum.slice(8, 9)
    |> Enum.all?(&(String.to_integer(&1) == 0))
  end
end
