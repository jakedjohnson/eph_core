defmodule Mix.Tasks.Eph.ObserverPositionSanityCheck do
  @moduledoc """
  Sanity check for Stage 03: ObserverPosition.

  Validates WGS84 geodetic-to-ECEF conversion and basic invariants
  for inertial rotation and local basis construction.

  ## Usage

      mix eph.observer_position_sanity_check
      mix eph.observer_position_sanity_check --verbose
      mix eph.observer_position_sanity_check --tolerance 0.001
  """

  use Mix.Task

  alias EphCore.Attitude.Sidereal
  alias AstroUtils.Vector
  alias EphCore.Geometry.Geodetic
  alias EphCore.SnapshotPipeline

  @shortdoc "Validate ObserverPosition outputs against references"

  @reference_locations [
    %{
      name: "Equator/Prime Meridian",
      lat_deg: 0.0,
      lon_deg: 0.0,
      height_m: 0.0,
      expected_ecef_km: {6_378.137, 0.0, 0.0},
      tolerance_km: 1.0e-3,
      source: "WGS84 semi-major axis"
    },
    %{
      name: "North Pole",
      lat_deg: 90.0,
      lon_deg: 0.0,
      height_m: 0.0,
      expected_ecef_km: {0.0, 0.0, 6_356.7523142},
      tolerance_km: 1.0e-3,
      source: "WGS84 semi-minor axis"
    },
    %{
      name: "Grand Forks (Skyfield)",
      lat_deg: 47.91149743202343,
      lon_deg: -97.06920927133187,
      height_m: 255.1,
      expected_ecef_km: {-527.125218019622, -4250.636731834292, 4710.47538195714},
      tolerance_km: 1.0e-3,
      source: "Skyfield ECEF snapshot"
    }
  ]

  @impl true
  def run(args) do
    start_tables()

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          tolerance: :float,
          verbose: :boolean
        ],
        aliases: [t: :tolerance, v: :verbose]
      )

    tolerance = Keyword.get(opts, :tolerance, 1.0e-6)
    verbose? = Keyword.get(opts, :verbose, false)

    results = []

    results = results ++ validate_reference_locations(tolerance, verbose?)
    results = results ++ validate_pipeline_invariants(tolerance, verbose?)

    print_summary(results)
  end

  defp validate_reference_locations(_tolerance, verbose?) do
    Mix.shell().info("\n" <> header("Geodetic to ECEF Reference Checks"))

    Enum.map(@reference_locations, fn ref ->
      computed = Geodetic.to_ecef_km(ref.lat_deg, ref.lon_deg, ref.height_m)
      diff = max_tuple_delta(computed, ref.expected_ecef_km)
      pass = diff <= ref.tolerance_km

      if verbose? or not pass do
        status = if pass, do: "✅", else: "❌"

        Mix.shell().info(
          "  #{status} #{ref.name}: expected=#{format_tuple(ref.expected_ecef_km)}, got=#{format_tuple(computed)}, diff=#{diff} km (#{ref.source})"
        )
      end

      %{name: "#{ref.name} ECEF", pass: pass, diff: diff}
    end)
  end

  defp validate_pipeline_invariants(tolerance, verbose?) do
    Mix.shell().info("\n" <> header("Pipeline Invariants"))

    {:ok, snapshot} =
      SnapshotPipeline.observe(
        ~U[2026-01-14 00:00:00Z],
        %{lat: 44.95, lon: -93.27, height: 260.0},
        []
      )

    ecef = snapshot.observer_position.ecef_position_km
    inertial = snapshot.observer_position.inertial_position_km
    %{east: east, north: north, up: up} = snapshot.observer_position.local_basis

    results = []

    mag_diff = abs(Vector.magnitude(ecef) - Vector.magnitude(inertial))
    mag_pass = mag_diff <= tolerance

    if verbose? or not mag_pass do
      status = if mag_pass, do: "✅", else: "❌"
      Mix.shell().info("  #{status} Magnitude preserved: diff=#{mag_diff} km")
    end

    results = [%{name: "Inertial magnitude preserved", pass: mag_pass, diff: mag_diff} | results]

    basis_dot =
      Enum.max([
        abs(Vector.dot(east, north)),
        abs(Vector.dot(east, up)),
        abs(Vector.dot(north, up))
      ])

    basis_pass = basis_dot <= tolerance

    if verbose? or not basis_pass do
      status = if basis_pass, do: "✅", else: "❌"
      Mix.shell().info("  #{status} Basis orthogonality: max_dot=#{basis_dot}")
    end

    results = [%{name: "Basis orthogonality", pass: basis_pass, diff: basis_dot} | results]

    basis_mag =
      Enum.max([
        abs(Vector.magnitude(east) - 1.0),
        abs(Vector.magnitude(north) - 1.0),
        abs(Vector.magnitude(up) - 1.0)
      ])

    basis_mag_pass = basis_mag <= tolerance

    if verbose? or not basis_mag_pass do
      status = if basis_mag_pass, do: "✅", else: "❌"
      Mix.shell().info("  #{status} Basis normalization: max_mag_diff=#{basis_mag}")
    end

    results = [%{name: "Basis normalization", pass: basis_mag_pass, diff: basis_mag} | results]

    handedness =
      Vector.cross(north, east)
      |> Vector.normalize()
      |> Vector.dot(Vector.normalize(up))
      |> then(&abs(1.0 - &1))

    handedness_pass = handedness <= tolerance

    if verbose? or not handedness_pass do
      status = if handedness_pass, do: "✅", else: "❌"
      Mix.shell().info("  #{status} Basis handedness: diff=#{handedness}")
    end

    results = [
      %{name: "Basis right-handed (north × east)", pass: handedness_pass, diff: handedness}
      | results
    ]

    lon_deg = snapshot.intent.observer.lon_deg
    gmst = snapshot.earth_orientation.gmst_degrees
    expected_lmst = Sidereal.normalize_angle(gmst + lon_deg)
    lmst_diff = abs(snapshot.observer_position.lmst_deg - expected_lmst)
    lmst_pass = lmst_diff <= tolerance

    if verbose? or not lmst_pass do
      status = if lmst_pass, do: "✅", else: "❌"
      Mix.shell().info("  #{status} LMST consistency: diff=#{lmst_diff} deg")
    end

    [%{name: "LMST consistency", pass: lmst_pass, diff: lmst_diff} | results]
  end

  defp max_tuple_delta({ax, ay, az}, {bx, by, bz}) do
    Enum.max([abs(ax - bx), abs(ay - by), abs(az - bz)])
  end

  defp format_tuple({x, y, z}) do
    "{#{Float.round(x, 6)}, #{Float.round(y, 6)}, #{Float.round(z, 6)}}"
  end

  defp header(title), do: "━━━ #{title} ━━━"

  defp start_tables do
    [
      EphCore.AstronomicalTime.Tables.LeapSeconds,
      EphCore.AstronomicalTime.Tables.EarthOrientationParameters,
      EphCore.Attitude.Tables.NutationIAU2000A
    ]
    |> Enum.each(&ensure_started/1)
  end

  defp ensure_started(mod) do
    case mod.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> Mix.raise("Failed to start #{inspect(mod)}: #{inspect(reason)}")
    end
  end

  defp print_summary(results) do
    total = length(results)
    passed = Enum.count(results, & &1.pass)
    failed = total - passed

    Mix.shell().info("\n" <> header("Summary"))
    Mix.shell().info("  Total: #{total} | Passed: #{passed} | Failed: #{failed}")

    if failed > 0 do
      Mix.shell().info("\n  ❌ FAILED CHECKS:")

      results
      |> Enum.reject(& &1.pass)
      |> Enum.each(fn r ->
        Mix.shell().info("     • #{r.name} (diff: #{r.diff})")
      end)

      Mix.raise("ObserverPosition sanity check failed with #{failed} errors")
    else
      Mix.shell().info("\n  ✅ ALL CHECKS PASSED")
    end
  end
end
