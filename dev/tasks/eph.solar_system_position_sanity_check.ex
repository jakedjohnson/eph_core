defmodule Mix.Tasks.Eph.SolarSystemPositionSanityCheck do
  use Mix.Task

  @shortdoc "Validate SPK kernel reading against Skyfield"

  alias EphCore.Ephemeris
  alias EphCore.Ephemeris.Kernels
  alias AstroUtils.Angle
  alias EphCore.Geometry.Horizon
  alias EphCore.SnapshotPipeline.{AstronomicalTime, Intent, SolarSystemPosition}

  @switches [
    verbose: :boolean,
    tolerance: :float,
    ecliptic_tolerance: :float,
    true_ecliptic_tolerance: :float,
    ra_dec_tolerance: :float,
    east_horizon_ecliptic_longitude_tolerance: :float,
    meridian_ecliptic_longitude_tolerance: :float,
    target: :string,
    utc: :string,
    benchmark: :boolean,
    iterations: :integer
  ]

  @reference_positions [
    %{name: "Sun at J2000.0", utc: ~U[2000-01-01 12:00:00Z], target: :sun},
    %{name: "Jupiter at 2025-01-01", utc: ~U[2025-01-01 00:00:00Z], target: :jupiter}
  ]

  @reference_ecliptic_utc ~U[1991-03-22 19:26:00Z]
  @reference_ecliptic_targets [:sun, :moon, :mercury, :venus, :mars, :jupiter, :saturn]
  @reference_observer %{lat_deg: 47.9115, lon_deg: -97.0692}

  @impl true
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: @switches)
    Application.ensure_all_started(:eph_core)

    results = []
    results = results ++ run_reference_positions(opts)
    results = results ++ run_reference_ecliptic_positions(opts)
    results = results ++ run_reference_ra_dec_positions(opts)
    results = results ++ run_reference_east_horizon_ecliptic_longitude(opts)
    results = results ++ run_reference_meridian_ecliptic_longitude(opts)
    results = results ++ run_custom_query(opts)

    if opts[:benchmark], do: run_benchmark(opts)

    print_summary(results, opts)
  end

  defp run_reference_positions(opts) do
    Enum.flat_map(@reference_positions, fn ref ->
      case compare_position(ref.utc, ref.target, opts) do
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
      with {:ok, utc_dt} <- parse_utc(utc),
           {:ok, result} <- compare_position(utc_dt, String.to_atom(target), opts) do
        [Map.put(result, :name, "Custom query")]
      else
        {:error, reason} -> [error_result("Custom query", {:error, reason})]
      end
    else
      []
    end
  end

  defp run_reference_ecliptic_positions(opts) do
    if is_nil(opts[:ecliptic_tolerance]) do
      Mix.shell().info("Using default ecliptic tolerance: 0.005 deg")
    end

    if is_nil(opts[:true_ecliptic_tolerance]) do
      Mix.shell().info("Using default true-of-date ecliptic tolerance: 0.01 deg")
    end

    run_reference_ecliptic_frame(:j2000, opts) ++
      run_reference_ecliptic_frame(:mean_of_date, opts) ++
      run_reference_ecliptic_frame(:true_of_date, opts)
  end

  defp run_reference_ecliptic_frame(frame, opts) do
    Enum.flat_map(@reference_ecliptic_targets, fn target ->
      name = "#{format_frame_name(frame)} ecliptic (#{target})"

      case compare_ecliptic_frame(@reference_ecliptic_utc, target, frame, opts) do
        {:ok, result} -> [Map.put(result, :name, name)]
        {:error, :skyfield_unavailable} -> []
        {:error, _} = error -> [error_result(name, error)]
      end
    end)
  end

  defp run_reference_ra_dec_positions(opts) do
    if is_nil(opts[:ra_dec_tolerance]) do
      Mix.shell().info("Using default RA/Dec tolerance: 0.005 deg")
    end

    Enum.flat_map(@reference_ecliptic_targets, fn target ->
      name = "RA/Dec (#{target})"

      case compare_ra_dec(@reference_ecliptic_utc, target, opts) do
        {:ok, result} -> [Map.put(result, :name, name)]
        {:error, :skyfield_unavailable} -> []
        {:error, _} = error -> [error_result(name, error)]
      end
    end)
  end

  defp run_reference_east_horizon_ecliptic_longitude(opts) do
    name = "East horizon ecliptic longitude reference"

    if is_nil(opts[:east_horizon_ecliptic_longitude_tolerance]) do
      Mix.shell().info("Using default east horizon ecliptic longitude tolerance: 0.2 deg")
    end

    case compare_east_horizon_ecliptic_longitude(
           @reference_ecliptic_utc,
           @reference_observer,
           opts
         ) do
      {:ok, result} -> [Map.put(result, :name, name)]
      {:error, :skyfield_unavailable} -> []
      {:error, _} = error -> [error_result(name, error)]
    end
  end

  defp run_reference_meridian_ecliptic_longitude(opts) do
    name = "Meridian ecliptic longitude reference"

    if is_nil(opts[:meridian_ecliptic_longitude_tolerance]) do
      Mix.shell().info("Using default meridian ecliptic longitude tolerance: 0.3 deg")
    end

    case compare_meridian_ecliptic_longitude(@reference_ecliptic_utc, @reference_observer, opts) do
      {:ok, result} -> [Map.put(result, :name, name)]
      {:error, :skyfield_unavailable} -> []
      {:error, _} = error -> [error_result(name, error)]
    end
  end

  defp compare_position(utc, target, opts) do
    with {:ok, jd_tt} <- jd_tt_for(utc),
         {:ok, elixir_state} <- Ephemeris.geocentric_state(jd_tt, target),
         {:ok, skyfield_position} <- skyfield_position(utc, target) do
      tolerance_km = opts[:tolerance] || 1.0
      diff_km = distance_km(elixir_state.geocentric_position_km, skyfield_position)

      {:ok,
       %{
         type: :position,
         target: target,
         utc: utc,
         elixir: elixir_state.geocentric_position_km,
         skyfield: skyfield_position,
         diff_km: diff_km,
         tolerance_km: tolerance_km,
         pass?: diff_km <= tolerance_km
       }}
    end
  end

  defp compare_ecliptic_frame(utc, target, frame, opts) do
    with {:ok, snapshot} <- Intent.new(%{utc: utc, models: %{ecliptic_frame: frame}}),
         snapshot <- AstronomicalTime.resolve(snapshot),
         %SolarSystemPosition{} = elixir_state <- SolarSystemPosition.resolve(snapshot, target),
         {:ok, {sky_lon, sky_lat}} <- skyfield_ecliptic(utc, target, frame) do
      case {elixir_state.ecliptic_longitude, elixir_state.ecliptic_latitude} do
        {lon, lat} when is_number(lon) and is_number(lat) ->
          tolerance_deg =
            case frame do
              :true_of_date -> opts[:true_ecliptic_tolerance] || 0.01
              _ -> opts[:ecliptic_tolerance] || 0.005
            end

          diff_lon = angular_diff_deg(lon, sky_lon)
          diff_lat = abs(lat - sky_lat)
          diff_deg = max(diff_lon, diff_lat)

          {:ok,
           %{
             type: :ecliptic,
             target: target,
             utc: utc,
             elixir: {lon, lat},
             skyfield: {sky_lon, sky_lat},
             diff_deg: diff_deg,
             tolerance_deg: tolerance_deg,
             pass?: diff_deg <= tolerance_deg
           }}

        _ ->
          {:error, :missing_ecliptic_output}
      end
    end
  end

  defp compare_ra_dec(utc, target, opts) do
    with {:ok, snapshot} <- Intent.new(%{utc: utc}),
         snapshot <- AstronomicalTime.resolve(snapshot),
         %SolarSystemPosition{} = elixir_state <- SolarSystemPosition.resolve(snapshot, target),
         {:ok, {sky_ra, sky_dec}} <- skyfield_ra_dec(utc, target) do
      case {elixir_state.right_ascension, elixir_state.declination} do
        {ra, dec} when is_number(ra) and is_number(dec) ->
          tolerance_deg = opts[:ra_dec_tolerance] || 0.005
          diff_ra = angular_diff_deg(ra, sky_ra)
          diff_dec = abs(dec - sky_dec)
          diff_deg = max(diff_ra, diff_dec)

          {:ok,
           %{
             type: :ra_dec,
             target: target,
             utc: utc,
             elixir: {ra, dec},
             skyfield: {sky_ra, sky_dec},
             diff_deg: diff_deg,
             tolerance_deg: tolerance_deg,
             pass?: diff_deg <= tolerance_deg
           }}

        _ ->
          {:error, :missing_ra_dec_output}
      end
    end
  end

  defp compare_east_horizon_ecliptic_longitude(utc, observer, opts) do
    with {:ok, snapshot} <- Intent.new(%{utc: utc}),
         snapshot <- AstronomicalTime.resolve(snapshot),
         {:ok, skyfield_east_horizon_ecliptic_longitude} <-
           skyfield_east_horizon_ecliptic_longitude(utc, observer) do
      result =
        Horizon.ecliptic_lon_at_east_horizon(
          snapshot.astronomical_time.jd_tt,
          observer.lat_deg,
          observer.lon_deg,
          sidereal_time_type: :apparent,
          obliquity_model: :true_of_date
        )

      tolerance_deg = opts[:east_horizon_ecliptic_longitude_tolerance] || 0.2

      diff_deg =
        angular_diff_deg(
          result.east_horizon_ecliptic_longitude,
          skyfield_east_horizon_ecliptic_longitude
        )

      {:ok,
       %{
         type: :east_horizon_ecliptic_longitude,
         utc: utc,
         target: :east_horizon_ecliptic_longitude,
         elixir: result.east_horizon_ecliptic_longitude,
         skyfield: skyfield_east_horizon_ecliptic_longitude,
         diff_deg: diff_deg,
         tolerance_deg: tolerance_deg,
         pass?: diff_deg <= tolerance_deg
       }}
    end
  end

  defp compare_meridian_ecliptic_longitude(utc, observer, opts) do
    with {:ok, snapshot} <- Intent.new(%{utc: utc}),
         snapshot <- AstronomicalTime.resolve(snapshot),
         {:ok, skyfield_meridian_ecliptic_longitude} <-
           skyfield_meridian_ecliptic_longitude(utc, observer) do
      result =
        Horizon.ecliptic_lon_on_meridian(
          snapshot.astronomical_time.jd_tt,
          observer.lon_deg,
          sidereal_time_type: :apparent,
          obliquity_model: :true_of_date
        )

      tolerance_deg = opts[:meridian_ecliptic_longitude_tolerance] || 0.3

      diff_deg =
        angular_diff_deg(result.meridian_ecliptic_longitude, skyfield_meridian_ecliptic_longitude)

      {:ok,
       %{
         type: :meridian_ecliptic_longitude,
         utc: utc,
         target: :meridian_ecliptic_longitude,
         elixir: result.meridian_ecliptic_longitude,
         skyfield: skyfield_meridian_ecliptic_longitude,
         diff_deg: diff_deg,
         tolerance_deg: tolerance_deg,
         pass?: diff_deg <= tolerance_deg
       }}
    end
  end

  defp skyfield_position(utc, target) do
    case python_available?() and skyfield_available?() do
      true -> run_skyfield_query(utc, target)
      false -> {:error, :skyfield_unavailable}
    end
  end

  defp skyfield_ecliptic(utc, target, frame) do
    case python_available?() and skyfield_available?() do
      true ->
        case frame do
          :j2000 -> run_skyfield_ecliptic_j2000_query(utc, target)
          :mean_of_date -> run_skyfield_ecliptic_mean_query(utc, target)
          :true_of_date -> run_skyfield_ecliptic_true_query(utc, target)
        end

      false ->
        {:error, :skyfield_unavailable}
    end
  end

  defp skyfield_ra_dec(utc, target) do
    case python_available?() and skyfield_available?() do
      true -> run_skyfield_ra_dec_query(utc, target)
      false -> {:error, :skyfield_unavailable}
    end
  end

  defp skyfield_east_horizon_ecliptic_longitude(utc, observer) do
    case python_available?() and skyfield_available?() do
      true -> run_skyfield_east_horizon_ecliptic_longitude_query(utc, observer)
      false -> {:error, :skyfield_unavailable}
    end
  end

  defp skyfield_meridian_ecliptic_longitude(utc, observer) do
    case python_available?() and skyfield_available?() do
      true -> run_skyfield_meridian_ecliptic_longitude_query(utc, observer)
      false -> {:error, :skyfield_unavailable}
    end
  end

  defp run_skyfield_query(utc, target) do
    kernel_path = Kernels.spk_path("de440s.bsp")
    skyfield_target = skyfield_target_name(target)

    script = """
    from skyfield.api import load
    ts = load.timescale()
    planets = load(r'#{kernel_path}')
    t = ts.utc(#{utc.year}, #{utc.month}, #{utc.day}, #{utc.hour}, #{utc.minute}, #{utc.second})
    earth = planets['earth']
    target = planets['#{skyfield_target}']
    earth_pos = earth.at(t).position.km
    target_pos = target.at(t).position.km
    pos = target_pos - earth_pos
    print(f"{pos[0]},{pos[1]},{pos[2]}")
    """

    case System.cmd("python3", ["-c", script]) do
      {output, 0} ->
        parse_position(String.trim(output))

      _ ->
        {:error, :skyfield_unavailable}
    end
  end

  defp run_skyfield_ecliptic_j2000_query(utc, target) do
    kernel_path = Kernels.spk_path("de440s.bsp")
    skyfield_target = skyfield_target_name(target)

    script = """
    from skyfield.api import load
    from skyfield.framelib import ecliptic_J2000_frame
    ts = load.timescale()
    planets = load(r'#{kernel_path}')
    t = ts.utc(#{utc.year}, #{utc.month}, #{utc.day}, #{utc.hour}, #{utc.minute}, #{utc.second})
    earth = planets['earth']
    target = planets['#{skyfield_target}']
    astrometric = earth.at(t).observe(target)
    lat, lon, _dist = astrometric.frame_latlon(ecliptic_J2000_frame)
    print(f"{lon.degrees},{lat.degrees}")
    """

    case System.cmd("python3", ["-c", script]) do
      {output, 0} ->
        parse_lon_lat(String.trim(output))

      _ ->
        {:error, :skyfield_unavailable}
    end
  end

  defp run_skyfield_ecliptic_mean_query(utc, target) do
    kernel_path = Kernels.spk_path("de440s.bsp")
    skyfield_target = skyfield_target_name(target)

    script = """
    from skyfield.api import load
    from skyfield.framelib import ecliptic_frame
    ts = load.timescale()
    planets = load(r'#{kernel_path}')
    t = ts.utc(#{utc.year}, #{utc.month}, #{utc.day}, #{utc.hour}, #{utc.minute}, #{utc.second})
    earth = planets['earth']
    target = planets['#{skyfield_target}']
    astrometric = earth.at(t).observe(target)
    lat, lon, _dist = astrometric.frame_latlon(ecliptic_frame)
    print(f"{lon.degrees},{lat.degrees}")
    """

    case System.cmd("python3", ["-c", script]) do
      {output, 0} ->
        parse_lon_lat(String.trim(output))

      _ ->
        {:error, :skyfield_unavailable}
    end
  end

  defp run_skyfield_ecliptic_true_query(utc, target) do
    kernel_path = Kernels.spk_path("de440s.bsp")
    skyfield_target = skyfield_target_name(target)

    script = """
    from skyfield.api import load
    from skyfield.framelib import ecliptic_frame
    ts = load.timescale()
    planets = load(r'#{kernel_path}')
    t = ts.utc(#{utc.year}, #{utc.month}, #{utc.day}, #{utc.hour}, #{utc.minute}, #{utc.second})
    earth = planets['earth']
    target = planets['#{skyfield_target}']
    astrometric = earth.at(t).observe(target)
    apparent = astrometric.apparent()
    lat, lon, _dist = apparent.frame_latlon(ecliptic_frame)
    print(f"{lon.degrees},{lat.degrees}")
    """

    case System.cmd("python3", ["-c", script]) do
      {output, 0} ->
        parse_lon_lat(String.trim(output))

      _ ->
        {:error, :skyfield_unavailable}
    end
  end

  defp format_frame_name(:j2000), do: "J2000"
  defp format_frame_name(:mean_of_date), do: "Mean-of-date"
  defp format_frame_name(:true_of_date), do: "True-of-date"

  defp run_skyfield_ra_dec_query(utc, target) do
    kernel_path = Kernels.spk_path("de440s.bsp")
    skyfield_target = skyfield_target_name(target)

    script = """
    from skyfield.api import load
    ts = load.timescale()
    planets = load(r'#{kernel_path}')
    t = ts.utc(#{utc.year}, #{utc.month}, #{utc.day}, #{utc.hour}, #{utc.minute}, #{utc.second})
    earth = planets['earth']
    target = planets['#{skyfield_target}']
    astrometric = earth.at(t).observe(target)
    ra, dec, _dist = astrometric.radec()
    print(f"{ra._degrees},{dec.degrees}")
    """

    case System.cmd("python3", ["-c", script]) do
      {output, 0} ->
        parse_lon_lat(String.trim(output))

      _ ->
        {:error, :skyfield_unavailable}
    end
  end

  defp run_skyfield_east_horizon_ecliptic_longitude_query(utc, observer) do
    script = """
    from skyfield.api import load
    import math
    ts = load.timescale()
    t = ts.utc(#{utc.year}, #{utc.month}, #{utc.day}, #{utc.hour}, #{utc.minute}, #{utc.second})

    lat = #{observer.lat_deg}
    lon = #{observer.lon_deg}

    gast = t.gast
    lst = (gast * 15.0 + lon) % 360.0
    eps = 23.4393

    lst_rad = math.radians(lst)
    eps_rad = math.radians(eps)
    lat_rad = math.radians(lat)

    # Standard east horizon ecliptic longitude formula from Meeus "Astronomical Algorithms":
    # tan(λ_eh) = -cos(RAMC) / (sin(RAMC)*cos(eps) + tan(lat)*sin(eps))
    # Rearranged for atan2(y, x): y = cos(RAMC), x = -(sin(eps)*tan(lat) + cos(eps)*sin(RAMC))
    east_horizon_ecliptic_lon = math.atan2(
        math.cos(lst_rad),
        -(math.sin(eps_rad) * math.tan(lat_rad) + math.cos(eps_rad) * math.sin(lst_rad))
    )
    east_horizon_ecliptic_lon_deg = math.degrees(east_horizon_ecliptic_lon) % 360.0
    print(f"{east_horizon_ecliptic_lon_deg}")
    """

    case System.cmd("python3", ["-c", script]) do
      {output, 0} ->
        {value, _} = Float.parse(String.trim(output))
        {:ok, value}

      _ ->
        {:error, :skyfield_unavailable}
    end
  end

  defp run_skyfield_meridian_ecliptic_longitude_query(utc, observer) do
    script = """
    from skyfield.api import load
    import math
    ts = load.timescale()
    t = ts.utc(#{utc.year}, #{utc.month}, #{utc.day}, #{utc.hour}, #{utc.minute}, #{utc.second})

    lon = #{observer.lon_deg}
    gast = t.gast
    lst = (gast * 15.0 + lon) % 360.0
    eps = 23.4393

    lst_rad = math.radians(lst)
    eps_rad = math.radians(eps)

    meridian_ecliptic_longitude = math.atan2(math.sin(lst_rad), math.cos(lst_rad) * math.cos(eps_rad))
    meridian_ecliptic_longitude_deg = math.degrees(meridian_ecliptic_longitude) % 360.0
    print(f"{meridian_ecliptic_longitude_deg}")
    """

    case System.cmd("python3", ["-c", script]) do
      {output, 0} ->
        {value, _} = Float.parse(String.trim(output))
        {:ok, value}

      _ ->
        {:error, :skyfield_unavailable}
    end
  end

  defp parse_position(output) do
    case String.split(output, ",") do
      [x, y, z] ->
        {:ok, {String.to_float(x), String.to_float(y), String.to_float(z)}}

      _ ->
        {:error, :invalid_skyfield_output}
    end
  end

  defp parse_lon_lat(output) do
    case String.split(output, ",") do
      [lon, lat] ->
        {:ok, {String.to_float(lon), String.to_float(lat)}}

      _ ->
        {:error, :invalid_skyfield_output}
    end
  end

  defp skyfield_target_name(:jupiter), do: "jupiter barycenter"
  defp skyfield_target_name(:mars), do: "mars barycenter"
  defp skyfield_target_name(:saturn), do: "saturn barycenter"
  defp skyfield_target_name(:uranus), do: "uranus barycenter"
  defp skyfield_target_name(:neptune), do: "neptune barycenter"
  defp skyfield_target_name(:pluto), do: "pluto barycenter"
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

  defp jd_tt_for(utc) do
    with {:ok, snapshot} <- Intent.new(%{utc: utc}) do
      snapshot = AstronomicalTime.resolve(snapshot)
      {:ok, snapshot.astronomical_time.jd_tt}
    end
  end

  defp parse_utc(utc) do
    case DateTime.from_iso8601(utc) do
      {:ok, dt, 0} -> {:ok, dt}
      {:error, _} -> {:error, :invalid_utc}
    end
  end

  defp distance_km({x1, y1, z1}, {x2, y2, z2}) do
    :math.sqrt(:math.pow(x1 - x2, 2) + :math.pow(y1 - y2, 2) + :math.pow(z1 - z2, 2))
  end

  defp angular_diff_deg(a, b) do
    delta = abs(Angle.normalize_360(a - b))
    if delta > 180.0, do: 360.0 - delta, else: delta
  end

  defp run_benchmark(opts) do
    iterations = opts[:iterations] || 100
    target = String.to_atom(opts[:target] || "sun")

    utc =
      case opts[:utc] do
        nil ->
          ~U[2000-01-01 12:00:00Z]

        value ->
          case parse_utc(value) do
            {:ok, dt} -> dt
            {:error, _} -> ~U[2000-01-01 12:00:00Z]
          end
      end

    {:ok, jd_tt} = jd_tt_for(utc)

    {time_us, _} =
      :timer.tc(fn ->
        Enum.each(1..iterations, fn _ ->
          Ephemeris.geocentric_state(jd_tt, target)
        end)
      end)

    avg_us = time_us / iterations
    Mix.shell().info("Elixir avg: #{Float.round(avg_us, 2)} µs (#{iterations} iterations)")
  end

  defp print_summary(results, opts) do
    verbose = opts[:verbose] || false

    Enum.each(results, fn
      %{pass?: true} = result ->
        Mix.shell().info(summary_line(result, "PASS", verbose))

      %{pass?: false} = result ->
        Mix.shell().error(summary_line(result, "FAIL", true))

      %{error: error, name: name} ->
        Mix.shell().error("#{name}: ERROR #{inspect(error)}")
    end)

    if results == [] do
      Mix.shell().info("No Skyfield comparisons run (missing python3 or skyfield).")
    end
  end

  defp summary_line(result, status, verbose) do
    base =
      case result.type do
        :meridian_ecliptic_longitude ->
          "#{result.name} #{status} diff=#{Float.round(result.diff_deg, 6)} deg"

        :east_horizon_ecliptic_longitude ->
          "#{result.name} #{status} diff=#{Float.round(result.diff_deg, 6)} deg"

        :ra_dec ->
          "#{result.name} (#{result.target}) #{status} diff=#{Float.round(result.diff_deg, 6)} deg"

        :ecliptic ->
          "#{result.name} (#{result.target}) #{status} diff=#{Float.round(result.diff_deg, 6)} deg"

        _ ->
          "#{result.name} (#{result.target}) #{status} diff=#{Float.round(result.diff_km, 6)} km"
      end

    if verbose do
      case result.type do
        :meridian_ecliptic_longitude ->
          base <>
            " tol=#{result.tolerance_deg} deg elixir=#{inspect(result.elixir)} skyfield=#{inspect(result.skyfield)}"

        :east_horizon_ecliptic_longitude ->
          base <>
            " tol=#{result.tolerance_deg} deg elixir=#{inspect(result.elixir)} skyfield=#{inspect(result.skyfield)}"

        :ra_dec ->
          base <>
            " tol=#{result.tolerance_deg} deg elixir=#{inspect(result.elixir)} skyfield=#{inspect(result.skyfield)}"

        :ecliptic ->
          base <>
            " tol=#{result.tolerance_deg} deg elixir=#{inspect(result.elixir)} skyfield=#{inspect(result.skyfield)}"

        _ ->
          base <>
            " tol=#{result.tolerance_km} km elixir=#{inspect(result.elixir)} skyfield=#{inspect(result.skyfield)}"
      end
    else
      base
    end
  end

  defp error_result(name, {:error, reason}) do
    %{name: name, error: reason}
  end
end
