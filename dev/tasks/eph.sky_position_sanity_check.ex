defmodule Mix.Tasks.Eph.SkyPositionSanityCheck do
  use Mix.Task

  @shortdoc "Validate topocentric alt/az against Skyfield"

  alias EphCore.Ephemeris.Kernels
  alias EphCore.SnapshotPipeline

  @switches [
    verbose: :boolean,
    tolerance: :float,
    target: :string,
    utc: :string,
    lat: :float,
    lon: :float,
    height: :float
  ]

  @reference_cases [
    %{
      name: "Sun at 2025-01-01, Minneapolis",
      utc: ~U[2025-01-01 00:00:00Z],
      target: :sun,
      observer: %{lat_deg: 44.95, lon_deg: -93.27, height_m: 260.0}
    },
    %{
      name: "Jupiter at 2025-06-01, Minneapolis",
      utc: ~U[2025-06-01 00:00:00Z],
      target: :jupiter,
      observer: %{lat_deg: 44.95, lon_deg: -93.27, height_m: 260.0}
    }
  ]

  @impl true
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: @switches)
    Application.put_env(:eph_core, :start_repo, false)
    Application.put_env(:eph_core, :start_endpoint, false)
    Application.ensure_all_started(:eph_core)

    results = []
    results = results ++ run_reference_cases(opts)
    results = results ++ run_custom_query(opts)

    print_summary(results, opts)
  end

  defp run_reference_cases(opts) do
    Enum.flat_map(@reference_cases, fn ref ->
      case compare_altaz(ref.utc, ref.observer, ref.target, opts) do
        {:ok, result} -> [Map.put(result, :name, ref.name)]
        {:error, :skyfield_unavailable} -> []
        {:error, _} = error -> [error_result(ref.name, error)]
      end
    end)
  end

  defp run_custom_query(opts) do
    utc = Keyword.get(opts, :utc)
    target = Keyword.get(opts, :target)

    if is_binary(utc) and is_binary(target) do
      observer = %{
        lat_deg: Keyword.get(opts, :lat, 44.95),
        lon_deg: Keyword.get(opts, :lon, -93.27),
        height_m: Keyword.get(opts, :height, 260.0)
      }

      with {:ok, utc_dt} <- parse_utc(utc),
           {:ok, result} <- compare_altaz(utc_dt, observer, String.to_atom(target), opts) do
        [Map.put(result, :name, "Custom query")]
      else
        {:error, reason} -> [error_result("Custom query", {:error, reason})]
      end
    else
      []
    end
  end

  defp compare_altaz(utc, observer, target, opts) do
    with {:ok, elixir_altaz} <- elixir_altaz(utc, observer, target),
         {:ok, skyfield_altaz} <- skyfield_altaz(utc, observer, target) do
      tolerance_deg = opts[:tolerance] || 0.1
      alt_diff = abs(elixir_altaz.altitude_deg - skyfield_altaz.altitude_deg)
      az_diff = angular_diff_deg(elixir_altaz.azimuth_deg, skyfield_altaz.azimuth_deg)

      {:ok,
       %{
         target: target,
         utc: utc,
         observer: observer,
         elixir: elixir_altaz,
         skyfield: skyfield_altaz,
         alt_diff_deg: alt_diff,
         az_diff_deg: az_diff,
         tolerance_deg: tolerance_deg,
         pass?: alt_diff <= tolerance_deg and az_diff <= tolerance_deg
       }}
    end
  end

  defp elixir_altaz(utc, observer, target) do
    # Use precession/nutation corrections to match Skyfield's default behavior
    opts = [corrections: %{precession_nutation: true}]

    case SnapshotPipeline.observe(utc, observer, [target], opts) do
      {:ok, observation} ->
        body = observation.bodies[target]

        {:ok,
         %{
           altitude_deg: body.altitude_deg,
           azimuth_deg: body.azimuth_deg,
           range_km: body.topocentric_range_km
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp skyfield_altaz(utc, observer, target) do
    case python_available?() and skyfield_available?() do
      true -> run_skyfield_query(utc, observer, target)
      false -> {:error, :skyfield_unavailable}
    end
  end

  defp run_skyfield_query(utc, observer, target) do
    kernel_path = Kernels.spk_path("de440s.bsp")
    skyfield_target = skyfield_target_name(target)

    script = """
    from skyfield.api import load, wgs84
    ts = load.timescale()
    planets = load(r'#{kernel_path}')
    t = ts.utc(#{utc.year}, #{utc.month}, #{utc.day}, #{utc.hour}, #{utc.minute}, #{utc.second})
    earth = planets['earth']
    target = planets['#{skyfield_target}']
    observer = wgs84.latlon(#{observer.lat_deg}, #{observer.lon_deg}, elevation_m=#{observer.height_m})
    apparent = (earth + observer).at(t).observe(target).apparent()
    alt, az, dist = apparent.altaz()
    print(f"{alt.degrees},{az.degrees},{dist.km}")
    """

    case System.cmd("python3", ["-c", script]) do
      {output, 0} ->
        parse_skyfield_output(String.trim(output))

      _ ->
        {:error, :skyfield_unavailable}
    end
  end

  defp parse_skyfield_output(output) do
    case String.split(output, ",") do
      [alt, az, range] ->
        {:ok,
         %{
           altitude_deg: String.to_float(alt),
           azimuth_deg: String.to_float(az),
           range_km: String.to_float(range)
         }}

      _ ->
        {:error, :invalid_skyfield_output}
    end
  end

  defp skyfield_target_name(:jupiter), do: "jupiter barycenter"
  defp skyfield_target_name(target) when is_atom(target), do: Atom.to_string(target)

  defp python_available? do
    case System.cmd("python3", ["-c", "print('ok')"]) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp skyfield_available? do
    case System.cmd("python3", ["-c", "import skyfield; print('ok')"]) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp parse_utc(utc) do
    case DateTime.from_iso8601(utc) do
      {:ok, dt, 0} -> {:ok, dt}
      {:error, _} -> {:error, :invalid_utc}
    end
  end

  defp angular_diff_deg(a, b) do
    diff = abs(a - b)
    min(diff, 360.0 - diff)
  end

  defp print_summary(results, opts) do
    verbose = opts[:verbose] || false

    Enum.each(results, fn
      %{pass?: true} = result ->
        Mix.shell().info(summary_line(result, "PASS", verbose))

      %{pass?: false} = result ->
        Mix.shell().error(summary_line(result, "FAIL", true))

      {:error, :skyfield_unavailable} ->
        Mix.shell().info("Skyfield unavailable; skipping checks.")
    end)
  end

  defp summary_line(result, status, verbose) do
    base =
      "#{status} #{result.name} (#{result.target}) alt diff=#{Float.round(result.alt_diff_deg, 4)}° " <>
        "az diff=#{Float.round(result.az_diff_deg, 4)}°"

    if verbose do
      base <>
        " elixir_alt=#{Float.round(result.elixir.altitude_deg, 4)}° " <>
        "elixir_az=#{Float.round(result.elixir.azimuth_deg, 4)}° " <>
        "skyfield_alt=#{Float.round(result.skyfield.altitude_deg, 4)}° " <>
        "skyfield_az=#{Float.round(result.skyfield.azimuth_deg, 4)}°"
    else
      base
    end
  end

  defp error_result(name, error) do
    %{
      name: name,
      error: error,
      pass?: false,
      alt_diff_deg: 0.0,
      az_diff_deg: 0.0,
      target: :unknown
    }
  end
end
