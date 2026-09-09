defmodule Mix.Tasks.Eph.EarthOrientationSanityCheck do
  @moduledoc """
  End-to-end sanity check for Earth orientation calculations.

  Validates GMST reference values, daily advance rate, optional Skyfield comparison,
  and rotation matrix orthonormality.
  """

  use Mix.Task

  alias EphCore.Attitude.Sidereal
  alias AstroUtils.Matrix3
  alias EphCore.SnapshotPipeline.{EarthOrientation, Intent}

  @shortdoc "Validate Earth orientation calculations"

  @gmst_j2000_expected 280.46061837
  @gmst_daily_advance_expected 360.985647

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          tolerance: :float,
          verbose: :boolean,
          offline: :boolean,
          only: :string,
          skyfield: :boolean
        ],
        aliases: [t: :tolerance, v: :verbose]
      )

    tolerance = Keyword.get(opts, :tolerance, 1.0e-3)
    verbose? = Keyword.get(opts, :verbose, false)
    offline? = Keyword.get(opts, :offline, false)
    skyfield? = Keyword.get(opts, :skyfield, false)
    only = parse_only_filter(Keyword.get(opts, :only))

    Mix.Task.run("app.start", ["--no-start"])
    {:ok, _} = EphCore.EarthOrientation.Tables.NutationIAU2000A.start_link()

    results = []

    results =
      if run_category?(:reference, only) do
        results ++ validate_gmst_reference(tolerance, verbose?)
      else
        results
      end

    results =
      if run_category?(:rate, only) do
        results ++ validate_gmst_daily_advance(tolerance, verbose?)
      else
        results
      end

    results =
      if run_category?(:matrix, only) do
        results ++ validate_rotation_matrix(tolerance, verbose?)
      else
        results
      end

    results =
      if skyfield? and not offline? and run_category?(:skyfield, only) do
        results ++ validate_against_skyfield(tolerance, verbose?)
      else
        if skyfield? and offline? and run_category?(:skyfield, only) do
          Mix.shell().info("\n⏭️  Skipping Skyfield validation (--offline)")
        end

        results
      end

    print_summary(results)
  end

  # ============================================================================
  # GMST Reference
  # ============================================================================

  defp validate_gmst_reference(tolerance, verbose?) do
    Mix.shell().info("\n" <> header("GMST Reference"))

    jd = 2_451_545.0
    gmst = Sidereal.gmst_iau_2006(jd, jd)
    diff = abs(gmst - @gmst_j2000_expected)
    pass = diff <= tolerance

    if verbose? or not pass do
      status = if pass, do: "✅", else: "❌"

      Mix.shell().info(
        "  #{status} GMST J2000: expected=#{@gmst_j2000_expected}, got=#{gmst}, diff=#{diff}"
      )
    end

    [%{name: "GMST J2000 reference", pass: pass, diff: diff}]
  end

  # ============================================================================
  # GMST Daily Advance
  # ============================================================================

  defp validate_gmst_daily_advance(tolerance, verbose?) do
    Mix.shell().info("\n" <> header("GMST Daily Advance"))

    jd = 2_451_545.0
    gmst_seconds_1 = Sidereal.gmst_iau_2006_seconds(jd, jd)
    gmst_seconds_2 = Sidereal.gmst_iau_2006_seconds(jd + 1.0, jd + 1.0)
    diff_degrees = (gmst_seconds_2 - gmst_seconds_1) * 360.0 / 86_400.0
    diff = abs(diff_degrees - @gmst_daily_advance_expected)
    pass = diff <= tolerance

    if verbose? or not pass do
      status = if pass, do: "✅", else: "❌"

      Mix.shell().info(
        "  #{status} GMST advance: expected=#{@gmst_daily_advance_expected}°, got=#{diff_degrees}°, diff=#{diff}°"
      )
    end

    [%{name: "GMST daily advance", pass: pass, diff: diff}]
  end

  # ============================================================================
  # Rotation Matrix
  # ============================================================================

  defp validate_rotation_matrix(tolerance, verbose?) do
    Mix.shell().info("\n" <> header("Rotation Matrix Orthonormality"))

    {:ok, snapshot} =
      Intent.new(
        utc: ~U[2026-01-14 00:00:00Z],
        models: %{earth_orientation: :gmst},
        corrections: %{precession_nutation: false}
      )

    snapshot = EphCore.SnapshotPipeline.AstronomicalTime.resolve(snapshot)
    snapshot = EarthOrientation.resolve(snapshot)
    matrix = snapshot.earth_orientation.rotation_matrix

    determinant = determinant(matrix)
    determinant_diff = abs(determinant - 1.0)
    determinant_ok = determinant_diff <= tolerance

    orthonormal_diff = orthonormal_diff(matrix)
    orthonormal_ok = orthonormal_diff <= tolerance

    if verbose? or not determinant_ok or not orthonormal_ok do
      det_status = if determinant_ok, do: "✅", else: "❌"
      ortho_status = if orthonormal_ok, do: "✅", else: "❌"

      Mix.shell().info("  #{det_status} det(R)=#{determinant} (diff=#{determinant_diff})")

      Mix.shell().info("  #{ortho_status} ||R·Rᵀ - I||ₘₐₓ=#{orthonormal_diff}")
    end

    [
      %{name: "Rotation matrix determinant", pass: determinant_ok, diff: determinant_diff},
      %{name: "Rotation matrix orthonormality", pass: orthonormal_ok, diff: orthonormal_diff}
    ]
  end

  # ============================================================================
  # Skyfield Validation (Optional)
  # ============================================================================

  defp validate_against_skyfield(tolerance, verbose?) do
    Mix.shell().info("\n" <> header("Skyfield GMST Validation"))

    jd = 2_451_545.0
    gmst = Sidereal.gmst_iau_2006(jd, jd)

    case skyfield_gmst(jd) do
      {:ok, skyfield_gmst} ->
        diff = abs(gmst - skyfield_gmst)
        pass = diff <= tolerance

        if verbose? or not pass do
          status = if pass, do: "✅", else: "❌"

          Mix.shell().info(
            "  #{status} Skyfield GMST: expected≈#{skyfield_gmst}, got=#{gmst}, diff=#{diff}"
          )
        end

        [%{name: "Skyfield GMST", pass: pass, diff: diff}]

      {:error, reason} ->
        Mix.shell().info("  ⚠️  Skyfield validation skipped: #{reason}")
        []
    end
  end

  defp skyfield_gmst(jd_tt) do
    if System.find_executable("python3") do
      script = """
      from skyfield.api import load
      ts = load.timescale()
      t = ts.tt_jd(#{jd_tt})
      print(t.gmst * 15.0)
      """

      case System.cmd("python3", ["-c", script], stderr_to_stdout: true) do
        {output, 0} ->
          output = String.trim(output)

          case Float.parse(output) do
            {value, _} -> {:ok, value}
            _ -> {:error, "unable to parse Skyfield output"}
          end

        {output, _} ->
          {:error, "python3 failed: #{String.trim(output)}"}
      end
    else
      {:error, "python3 not available"}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp header(title), do: "━━━ #{title} ━━━"

  defp parse_only_filter(nil), do: nil

  defp parse_only_filter(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)
    |> MapSet.new()
  end

  defp run_category?(_category, nil), do: true
  defp run_category?(category, filter), do: MapSet.member?(filter, category)

  defp determinant([[a, b, c], [d, e, f], [g, h, i]]) do
    a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
  end

  defp orthonormal_diff(matrix) do
    matrix
    |> Matrix3.multiply(transpose(matrix))
    |> max_identity_delta()
  end

  defp max_identity_delta(matrix) do
    identity = Matrix3.identity()

    for i <- 0..2, j <- 0..2 do
      value = matrix |> Enum.at(i) |> Enum.at(j)
      expected = identity |> Enum.at(i) |> Enum.at(j)
      abs(value - expected)
    end
    |> Enum.max()
  end

  defp transpose(matrix) do
    for i <- 0..2 do
      for j <- 0..2 do
        matrix |> Enum.at(j) |> Enum.at(i)
      end
    end
  end

  defp print_summary(results) do
    total = length(results)
    passed = Enum.count(results, & &1.pass)
    failed = total - passed

    Mix.shell().info("\n" <> header("Summary"))
    Mix.shell().info("  Total: #{total} | Passed: #{passed} | Failed: #{failed}")

    if failed > 0 do
      Mix.shell().info("\n  ❌ FAILED TESTS:")

      results
      |> Enum.reject(& &1.pass)
      |> Enum.each(fn r ->
        Mix.shell().info("     • #{r.name} (diff: #{r.diff})")
      end)

      Mix.raise("Sanity check failed with #{failed} errors")
    else
      Mix.shell().info("\n  ✅ ALL TESTS PASSED")
      Mix.shell().info("     EarthOrientation calculations look solid 🌍")
    end
  end
end
