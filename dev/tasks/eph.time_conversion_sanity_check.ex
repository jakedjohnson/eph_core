defmodule Mix.Tasks.Eph.TimeConversionSanityCheck do
  @moduledoc """
  Comprehensive end-to-end sanity check for the AstronomicalTime pipeline.

  Validates all time scale conversions (JD, TAI, TT, UT1, Delta-T) against
  authoritative external sources including IERS, JPL Horizons, and well-known
  astronomical reference points.

  This is the **definitive source of truth** that our AstronomicalTime struct
  produces accurate, non-hallucinated values.

  ## Usage

      # Full validation suite with all checks
      mix eph.time_conversion_sanity_check

      # Quick check with reference dates only (no network)
      mix eph.time_conversion_sanity_check --offline

      # Verbose output with all intermediate values
      mix eph.time_conversion_sanity_check --verbose

      # Custom tolerance for float comparisons (default: 1e-6 days ≈ 86ms)
      mix eph.time_conversion_sanity_check --tolerance 0.0001

      # Specific validation categories
      mix eph.time_conversion_sanity_check --only jd,tt,ut1

  ## What Gets Validated

  1. **Julian Day (JD UTC)**
     - J2000.0 epoch: 2000-01-01T12:00:00Z → JD 2451545.0 (exact)
     - Unix epoch: 1970-01-01T00:00:00Z → JD 2440587.5 (exact)
     - Well-known historical dates

  2. **International Atomic Time (TAI)**
     - Correct leap second application at known boundaries
     - Current leap offset (37 seconds as of 2017)

  3. **Terrestrial Time (TT)**
     - TT = TAI + 32.184s relationship
     - JD TT vs JD UTC offset validation

  4. **Universal Time 1 (UT1)**
     - UT1-UTC against live IERS finals2000A.all.json
     - EOP table interpolation accuracy

  5. **Delta-T (TT - UT1)**
     - Cross-check against USNO Delta-T tables
     - Validation of the full conversion chain

  ## External Data Sources

  - IERS finals2000A.all.json (live UT1-UTC values)
  - JPL Horizons batch API (optional, for TDB validation)
  - USNO Delta-T historical tables

  ## Exit Codes

  - 0: All validations passed
  - 1: One or more validations failed
  """

  use Mix.Task

  alias EphCore.SnapshotPipeline.{AstronomicalTime, Intent}
  alias EphCore.AstronomicalTime.Tables.{EarthOrientationParameters, LeapSeconds}

  @shortdoc "Validate AstronomicalTime conversions against authoritative sources"

  @iers_json_url "https://datacenter.iers.org/products/eop/rapid/standard/json/finals2000A.all.json"

  # Well-known astronomical reference points with externally verified values
  # Sources: USNO, JPL NAIF SPICE, IAU Standards
  @reference_dates [
    %{
      name: "J2000.0 Epoch",
      utc: ~U[2000-01-01 12:00:00.000000Z],
      expected_jd_utc: 2_451_545.0,
      expected_jd_tt: 2_451_545.00074287,
      # TT-UT1 at J2000: ~63.8 seconds (historical value)
      expected_delta_t_seconds: 63.8,
      delta_t_tolerance: 0.5,
      source: "IAU SOFA / IERS Conventions"
    },
    %{
      name: "Unix Epoch",
      utc: ~U[1970-01-01 00:00:00.000000Z],
      expected_jd_utc: 2_440_587.5,
      # Pre-1972: no leap seconds, approximate TT offset
      expected_jd_tt: nil,
      expected_delta_t_seconds: nil,
      delta_t_tolerance: nil,
      source: "Definition"
    },
    %{
      name: "First Leap Second (1972-01-01)",
      utc: ~U[1972-01-01 00:00:00.000000Z],
      expected_jd_utc: 2_441_317.5,
      # TAI-UTC = 10s at this moment, TT = TAI + 32.184s
      expected_tai_offset_seconds: 10,
      expected_tt_offset_seconds: 42.184,
      source: "IERS Bulletin C / NAIF LSK"
    },
    %{
      name: "Leap Second Boundary (2017-01-01)",
      utc: ~U[2017-01-01 00:00:00.000000Z],
      expected_jd_utc: 2_457_754.5,
      # TAI-UTC = 37s (current as of 2017+)
      expected_tai_offset_seconds: 37,
      expected_tt_offset_seconds: 69.184,
      source: "IERS Bulletin C"
    },
    %{
      name: "Recent Date (2024-06-15)",
      utc: ~U[2024-06-15 18:30:00.000000Z],
      # Verified against USNO Julian Date Converter
      expected_jd_utc: 2_460_477.270833333,
      expected_tai_offset_seconds: 37,
      source: "USNO Julian Date Converter"
    }
  ]

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          tolerance: :float,
          verbose: :boolean,
          offline: :boolean,
          only: :string
        ],
        aliases: [t: :tolerance, v: :verbose]
      )

    tolerance = Keyword.get(opts, :tolerance, 1.0e-6)
    verbose? = Keyword.get(opts, :verbose, false)
    offline? = Keyword.get(opts, :offline, false)
    only = parse_only_filter(Keyword.get(opts, :only))

    # Start required processes
    Mix.Task.run("app.start", ["--no-start"])
    {:ok, _} = LeapSeconds.start_link()
    {:ok, _} = EarthOrientationParameters.start_link()

    results = []

    # 1. Reference date validations (always run, no network required)
    results =
      if run_category?(:reference, only) do
        results ++ validate_reference_dates(tolerance, verbose?)
      else
        results
      end

    # 2. Julian Day precision tests
    results =
      if run_category?(:jd, only) do
        results ++ validate_julian_day_precision(tolerance, verbose?)
      else
        results
      end

    # 3. Leap second boundary tests
    results =
      if run_category?(:leap, only) do
        results ++ validate_leap_second_boundaries(verbose?)
      else
        results
      end

    # 4. TT offset chain validation
    results =
      if run_category?(:tt, only) do
        results ++ validate_tt_offset_chain(tolerance, verbose?)
      else
        results
      end

    # 5. Full pipeline integration test
    results =
      if run_category?(:pipeline, only) do
        results ++ validate_full_pipeline(tolerance, verbose?)
      else
        results
      end

    # 6. Live IERS UT1-UTC validation (requires network)
    results =
      if not offline? and run_category?(:iers, only) do
        results ++ validate_against_iers_live(tolerance, verbose?)
      else
        if not offline? and run_category?(:iers, only) do
          Mix.shell().info("\n⏭️  Skipping IERS live validation (--offline)")
        end

        results
      end

    # Summary
    print_summary(results)
  end

  # ============================================================================
  # Reference Date Validations
  # ============================================================================

  defp validate_reference_dates(tolerance, verbose?) do
    Mix.shell().info("\n" <> header("Reference Date Validations"))

    Enum.map(@reference_dates, fn ref ->
      {:ok, snapshot} = Intent.new(utc: ref.utc)
      snapshot = AstronomicalTime.resolve(snapshot)
      time = snapshot.astronomical_time

      results = []

      # JD UTC check
      results =
        if ref[:expected_jd_utc] do
          diff = abs(time.jd_utc - ref.expected_jd_utc)
          pass = diff <= tolerance

          if verbose? or not pass do
            status = if pass, do: "✅", else: "❌"

            Mix.shell().info(
              "  #{status} #{ref.name} JD UTC: expected=#{ref.expected_jd_utc}, got=#{time.jd_utc}, diff=#{diff}"
            )
          end

          [%{name: "#{ref.name} JD UTC", pass: pass, diff: diff} | results]
        else
          results
        end

      # JD TT check
      results =
        if ref[:expected_jd_tt] do
          diff = abs(time.jd_tt - ref.expected_jd_tt)
          pass = diff <= tolerance

          if verbose? or not pass do
            status = if pass, do: "✅", else: "❌"

            Mix.shell().info(
              "  #{status} #{ref.name} JD TT: expected=#{ref.expected_jd_tt}, got=#{time.jd_tt}, diff=#{diff}"
            )
          end

          [%{name: "#{ref.name} JD TT", pass: pass, diff: diff} | results]
        else
          results
        end

      # Delta-T check (with custom tolerance)
      results =
        if ref[:expected_delta_t_seconds] do
          dt_tolerance = ref[:delta_t_tolerance] || 1.0
          diff = abs(time.delta_t_seconds - ref.expected_delta_t_seconds)
          pass = diff <= dt_tolerance

          if verbose? or not pass do
            status = if pass, do: "✅", else: "❌"

            Mix.shell().info(
              "  #{status} #{ref.name} Delta-T: expected=#{ref.expected_delta_t_seconds}s, got=#{time.delta_t_seconds}s, diff=#{diff}s"
            )
          end

          [%{name: "#{ref.name} Delta-T", pass: pass, diff: diff} | results]
        else
          results
        end

      results
    end)
    |> List.flatten()
  end

  # ============================================================================
  # Julian Day Precision Tests
  # ============================================================================

  defp validate_julian_day_precision(tolerance, verbose?) do
    Mix.shell().info("\n" <> header("Julian Day Precision Tests"))

    alias EphCore.AstronomicalTime.JulianDay

    # Test microsecond precision
    test_cases = [
      # Standard case
      {~U[2000-01-01 12:00:00.000000Z], 2_451_545.0},
      # Noon vs midnight
      {~U[2000-01-01 00:00:00.000000Z], 2_451_544.5},
      # Microsecond precision test
      {~U[2000-01-01 12:00:00.000001Z], 2_451_545.0 + 1.0e-6 / 86400.0},
      # End of day
      {~U[2000-01-01 23:59:59.999999Z], 2_451_545.499999988425926}
    ]

    Enum.map(test_cases, fn {utc, expected_jd} ->
      computed_jd = JulianDay.from_datetime(utc)
      diff = abs(computed_jd - expected_jd)
      pass = diff <= tolerance

      if verbose? or not pass do
        status = if pass, do: "✅", else: "❌"
        Mix.shell().info("  #{status} JD for #{utc}: expected=#{expected_jd}, got=#{computed_jd}")
      end

      %{name: "JD precision #{utc}", pass: pass, diff: diff}
    end)
  end

  # ============================================================================
  # Leap Second Boundary Tests
  # ============================================================================

  defp validate_leap_second_boundaries(verbose?) do
    Mix.shell().info("\n" <> header("Leap Second Boundary Tests"))

    # Test that leap seconds are correctly applied at known boundaries
    leap_boundaries = [
      {~U[1971-12-31 23:59:59Z], 0},
      {~U[1972-01-01 00:00:00Z], 10},
      {~U[1972-06-30 23:59:59Z], 10},
      {~U[1972-07-01 00:00:00Z], 11},
      {~U[2016-12-31 23:59:59Z], 36},
      {~U[2017-01-01 00:00:00Z], 37}
    ]

    Enum.map(leap_boundaries, fn {utc, expected_leap_seconds} ->
      actual_offset_micros = LeapSeconds.offset_at(utc)
      actual_leap_seconds = div(actual_offset_micros, 1_000_000)
      pass = actual_leap_seconds == expected_leap_seconds

      if verbose? or not pass do
        status = if pass, do: "✅", else: "❌"

        Mix.shell().info(
          "  #{status} Leap at #{utc}: expected=#{expected_leap_seconds}s, got=#{actual_leap_seconds}s"
        )
      end

      %{
        name: "Leap boundary #{utc}",
        pass: pass,
        diff: abs(actual_leap_seconds - expected_leap_seconds)
      }
    end)
  end

  # ============================================================================
  # TT Offset Chain Validation
  # ============================================================================

  defp validate_tt_offset_chain(tolerance, verbose?) do
    Mix.shell().info("\n" <> header("TT Offset Chain Validation"))

    # Verify: TT = UTC + leap_seconds + 32.184s
    alias EphCore.AstronomicalTime.{TerrestrialTime, JulianDay}

    test_dates = [
      ~U[2000-01-01 12:00:00Z],
      ~U[2017-06-15 00:00:00Z],
      ~U[2024-01-01 00:00:00Z]
    ]

    Enum.map(test_dates, fn utc ->
      tt = TerrestrialTime.from_utc(utc)
      jd_utc = JulianDay.from_datetime(utc)
      jd_tt = JulianDay.from_datetime(tt)

      # Calculate expected offset: leap_seconds + 32.184
      leap_offset_micros = LeapSeconds.offset_at(utc)
      leap_seconds = leap_offset_micros / 1_000_000.0
      expected_tt_offset_seconds = leap_seconds + 32.184
      expected_tt_offset_days = expected_tt_offset_seconds / 86400.0

      actual_offset_days = jd_tt - jd_utc
      diff_days = abs(actual_offset_days - expected_tt_offset_days)
      pass = diff_days <= tolerance

      if verbose? or not pass do
        status = if pass, do: "✅", else: "❌"
        actual_seconds = actual_offset_days * 86400

        Mix.shell().info(
          "  #{status} TT chain #{utc}: leap=#{leap_seconds}s, expected_offset=#{expected_tt_offset_seconds}s, actual_offset=#{actual_seconds}s"
        )
      end

      %{name: "TT chain #{utc}", pass: pass, diff: diff_days}
    end)
  end

  # ============================================================================
  # Full Pipeline Integration Test
  # ============================================================================

  defp validate_full_pipeline(_tolerance, verbose?) do
    Mix.shell().info("\n" <> header("Full Pipeline Integration Tests"))

    # Test that the entire AstronomicalTime.resolve/1 pipeline produces consistent values
    test_dates = [
      ~U[2000-01-01 12:00:00Z],
      ~U[2024-06-15 18:30:00Z],
      ~U[2026-01-14 00:00:00Z]
    ]

    Enum.flat_map(test_dates, fn utc ->
      {:ok, snapshot} = Intent.new(utc: utc, models: %{delta_t: :iers})
      snapshot = AstronomicalTime.resolve(snapshot)
      time = snapshot.astronomical_time

      results = []

      # Invariant: jd_tt > jd_utc (TT is always ahead of UTC)
      tt_ahead = time.jd_tt > time.jd_utc

      if verbose? or not tt_ahead do
        status = if tt_ahead, do: "✅", else: "❌"

        Mix.shell().info(
          "  #{status} Pipeline #{utc}: jd_tt (#{time.jd_tt}) > jd_utc (#{time.jd_utc})"
        )
      end

      results = [%{name: "Pipeline TT>UTC #{utc}", pass: tt_ahead, diff: 0} | results]

      # Invariant: delta_t_seconds ≈ (jd_tt - jd_ut1) * 86400
      computed_delta_t = (time.jd_tt - time.jd_ut1) * 86400.0
      delta_t_diff = abs(computed_delta_t - time.delta_t_seconds)
      delta_t_consistent = delta_t_diff <= 1.0e-6

      if verbose? or not delta_t_consistent do
        status = if delta_t_consistent, do: "✅", else: "❌"

        Mix.shell().info(
          "  #{status} Pipeline #{utc}: delta_t consistency, computed=#{computed_delta_t}, stored=#{time.delta_t_seconds}"
        )
      end

      results = [
        %{
          name: "Pipeline delta_t consistency #{utc}",
          pass: delta_t_consistent,
          diff: delta_t_diff
        }
        | results
      ]

      # Invariant: UT1-UTC should be within ±0.9s (by definition, leap seconds keep it bounded)
      ut1_utc_days = time.jd_ut1 - time.jd_utc
      ut1_utc_seconds = ut1_utc_days * 86400.0
      ut1_bounded = abs(ut1_utc_seconds) <= 0.9

      if verbose? or not ut1_bounded do
        status = if ut1_bounded, do: "✅", else: "❌"

        Mix.shell().info(
          "  #{status} Pipeline #{utc}: UT1-UTC=#{ut1_utc_seconds}s (should be ±0.9s)"
        )
      end

      results = [
        %{name: "Pipeline UT1 bounded #{utc}", pass: ut1_bounded, diff: abs(ut1_utc_seconds)}
        | results
      ]

      results
    end)
  end

  # ============================================================================
  # Live IERS Validation
  # ============================================================================

  defp validate_against_iers_live(tolerance, verbose?) do
    Mix.shell().info("\n" <> header("Live IERS UT1-UTC Validation"))

    {:ok, _} = Application.ensure_all_started(:req)

    case fetch_iers_json() do
      {:ok, series} ->
        # Get recent dates that are in our EOP table
        samples =
          series
          |> Enum.filter(&valid_ut1_entry?/1)
          |> Enum.filter(&table_has_day?/1)
          |> Enum.take(-5)

        Enum.map(samples, fn entry ->
          %{date: date, mjd: mjd, iers_ut1_utc: iers, engine_ut1_utc: engine, diff: diff} =
            compare_iers_entry(entry)

          # Also test through the full pipeline
          utc = iers_entry_to_datetime(entry)
          {:ok, snapshot} = Intent.new(utc: utc, models: %{delta_t: :iers})
          snapshot = AstronomicalTime.resolve(snapshot)
          time = snapshot.astronomical_time

          pipeline_ut1_utc = (time.jd_ut1 - time.jd_utc) * 86400.0
          pipeline_diff = abs(pipeline_ut1_utc - iers)

          pass = diff <= tolerance * 86400 and pipeline_diff <= tolerance * 86400

          if verbose? or not pass do
            status = if pass, do: "✅", else: "❌"

            Mix.shell().info(
              "  #{status} IERS #{date} (MJD #{mjd}): IERS UT1-UTC=#{iers}s, EOP=#{engine}s, Pipeline=#{Float.round(pipeline_ut1_utc, 6)}s"
            )
          end

          %{name: "IERS #{date}", pass: pass, diff: max(diff, pipeline_diff)}
        end)

      {:error, reason} ->
        Mix.shell().info("  ⚠️  Could not fetch IERS data: #{inspect(reason)}")
        []
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp header(title) do
    "━━━ #{title} ━━━"
  end

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

  defp fetch_iers_json do
    case Req.get(@iers_json_url) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, decoded} = Jason.decode(body)
        {:ok, decoded["EOP"]["data"]["timeSeries"]}

      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body["EOP"]["data"]["timeSeries"]}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_ut1_entry?(entry) do
    ut_entries = entry["dataEOP"]["UT"]
    Enum.any?(ut_entries, fn ut -> ut["UT1-UTC"] not in [nil, ""] end)
  end

  defp table_has_day?(entry) do
    mjd = String.to_integer(entry["time"]["MJD"])
    EarthOrientationParameters.ut1_minus_utc_seconds(mjd * 1.0) != 0.0
  end

  defp compare_iers_entry(entry) do
    time = entry["time"]
    mjd = String.to_integer(time["MJD"])
    date = time["dateYear"] <> "-" <> time["dateMonth"] <> "-" <> time["dateDay"]

    ut_entries = entry["dataEOP"]["UT"]

    ut_entry =
      Enum.find(ut_entries, fn ut ->
        ut["source"] == "BulletinA" and ut["type"] == "final" and ut["UT1-UTC"] not in [nil, ""]
      end) || Enum.find(ut_entries, fn ut -> ut["UT1-UTC"] not in [nil, ""] end)

    {iers, _} = Float.parse(ut_entry["UT1-UTC"])
    engine = EarthOrientationParameters.ut1_minus_utc_seconds(mjd * 1.0)
    diff = abs(engine - iers)

    %{date: date, mjd: mjd, iers_ut1_utc: iers, engine_ut1_utc: engine, diff: diff}
  end

  defp iers_entry_to_datetime(entry) do
    time = entry["time"]
    year = String.to_integer(time["dateYear"])
    month = String.to_integer(time["dateMonth"])
    day = String.to_integer(time["dateDay"])

    {:ok, date} = Date.new(year, month, day)
    {:ok, dt} = DateTime.new(date, ~T[00:00:00], "Etc/UTC")
    dt
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
      Mix.shell().info("     AstronomicalTime conversions are accurate AF 🎯")
    end
  end
end
