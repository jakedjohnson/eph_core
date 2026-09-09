defmodule EphCore.Events.Almanac do
  @moduledoc """
  Full-year rise / transit / set almanac for one topocentric observer.

  For each body and each crossing it computes, **to one-second accuracy**:

  - **rise / set** — the apparent altitude of the body's centre crossing the
    USNO horizon threshold (going up / down).
  - **transit** — upper meridian crossing (local hour angle = 0), recording the
    apparent altitude and azimuth.

  ## Conventions (match Skyfield's `almanac`)

  Apparent altitude/azimuth and hour angle come from
  `EphCore.Corrections.ApparentPlace` (light-time + annual aberration + topocentric
  parallax on top of the validated IAU 2006/2000A precession-nutation frame).
  The horizon thresholds *encode* refraction + semidiameter rather than modelling
  them (Skyfield's `build_horizon_function`):

  | Body    | Centre altitude at rise/set                       |
  |---------|---------------------------------------------------|
  | Sun     | `-50'`  (`-0.8333°`) — 34' refraction + 16' limb  |
  | Moon    | `-34' - asin-free (R_moon / range)` (distance-dep) |
  | Planets | `-34'`  (`-0.5667°`)                              |

  ## Method (analytic-seed root-find)

  For each UTC day the algorithm:

  1. Computes **one** `ApparentPlace.frame` at noon UTC, capturing the
     slow-varying nutation, Earth velocity, and sidereal-time context.
  2. Evaluates `ApparentPlace.look` for every body at that frame to obtain
     the body's apparent RA/Dec.
  3. Uses the **Meeus closed-form hour-angle formula**
     (`cos H₀ = −tan φ tan δ`) to predict rise, set, and transit UTC times
     analytically from the noon RA/Dec and local sidereal time via the standard
     Meeus hour-angle formula.
  4. Places a narrow bracket (±`@bracket_minutes`) around each predicted
     time and confirms a sign change (altitude crossing threshold, or HA
     crossing zero) with two precise `ApparentPlace.look` evaluations.
  5. Refines within the confirmed bracket with a bracketed interpolation
     solver to ≤ `@refine_tolerance_us` (250 ms; the inverse-interpolation
     step converges well inside that, so the residual error stays ~0.5 s
     against Skyfield — comfortably inside the 1 s contract and the
     second-granularity UTC output), reusing the day's nutation and Earth
     velocity throughout.

  A full year for eight bodies therefore costs ~365 noon frames plus ~10
  evaluations per event, instead of a dense hourly grid, while staying in
  sub-second agreement with reference almanac implementations.
  """

  alias AstroUtils.Angle
  alias EphCore.Corrections.ApparentPlace

  @presets %{
    classic7: [:sun, :moon, :mercury, :venus, :mars, :jupiter, :saturn],
    classic8: [:sun, :moon, :mercury, :venus, :mars, :jupiter, :saturn, :uranus],
    modern10: [:sun, :moon, :mercury, :venus, :mars, :jupiter, :saturn, :uranus, :neptune, :pluto]
  }

  # USNO rise/set centre-altitude thresholds (degrees). Skyfield almanac.py:
  # _sun_horizon_radians = -50/21600*tau ; _refraction_radians = -34/21600*tau.
  @sun_threshold_deg -50.0 / 60.0
  @refraction_threshold_deg -34.0 / 60.0
  # Skyfield uses 1.7374e6 m and the small-angle radius R/d (radians), not asin.
  @moon_radius_km 1737.4

  @refine_tolerance_us 250_000
  @max_refine_iterations 80
  # Half-width of the bracket placed around each analytic seed (minutes).
  # Must be wide enough to absorb the seed error (a few minutes for planets,
  # up to ~15 min for the fast-moving Moon).
  @bracket_minutes 40
  # Sidereal / solar ratio (Meeus p.102) — 1 sidereal day ≈ 23h56m04s.
  @sidereal_rate 1.00273790935
  @sidereal_day_seconds 86_400.0 / @sidereal_rate

  @type observer :: %{optional(atom()) => float()}
  @type event :: %{
          required(:body) => String.t(),
          required(:event) => String.t(),
          required(:utc) => String.t(),
          required(:tt_jd) => float(),
          optional(:az_deg) => float(),
          optional(:alt_deg) => float()
        }

  @doc "Body atoms for a named preset (`:classic7` / `:classic8` / `:modern10`)."
  @spec preset(atom()) :: [atom()]
  def preset(name), do: Map.fetch!(@presets, name)

  @doc "All presets as a map."
  @spec presets() :: %{atom() => [atom()]}
  def presets, do: @presets

  @doc """
  USNO horizon threshold (centre altitude, degrees) for `body` at topocentric
  `range_km`. Only the Moon is range-dependent.
  """
  @spec horizon_threshold_deg(atom(), float()) :: float()
  def horizon_threshold_deg(:sun, _range_km), do: @sun_threshold_deg

  def horizon_threshold_deg(:moon, range_km),
    do: @refraction_threshold_deg - Angle.rad_to_deg(@moon_radius_km / range_km)

  def horizon_threshold_deg(_body, _range_km), do: @refraction_threshold_deg

  @doc """
  The half-open UTC span `[YEAR-01-01, (YEAR+1)-01-01)` for `year`.
  """
  @spec span(integer()) :: {DateTime.t(), DateTime.t()}
  def span(year) when is_integer(year) do
    start = DateTime.new!(Date.new!(year, 1, 1), ~T[00:00:00], "Etc/UTC")
    stop = DateTime.new!(Date.new!(year + 1, 1, 1), ~T[00:00:00], "Etc/UTC")
    {start, stop}
  end

  @doc """
  Compute every rise/transit/set event for `bodies` over `year`, flat and sorted
  by `tt_jd`. See module doc for the conventions and method.

  ## Options
  - `:step_seconds` — ignored (kept for API compat with the old dense-grid path).
  """
  @spec events(observer(), integer(), [atom()], keyword()) :: [event()]
  def events(observer, year, bodies, _opts \\ []) do
    {start_dt, stop_dt} = span(year)
    lat = observer[:lat] || observer[:latitude] || 0.0
    lon = observer[:lon] || observer[:longitude] || 0.0

    n_days = DateTime.diff(stop_dt, start_dt, :second) |> div(86_400)

    events =
      0..(n_days - 1)
      |> Task.async_stream(
        fn day_idx ->
          events_for_day(day_idx, start_dt, stop_dt, observer, bodies, lat, lon)
        end,
        max_concurrency: System.schedulers_online(),
        ordered: false,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, day_events} -> day_events end)

    events
    |> dedupe_close_events()
    |> Enum.sort_by(& &1.tt_jd)
  end

  # All rise/transit/set events for a single UTC day. Each day is independent
  # (its own noon frame, analytic seeds, and bracketed refinement), so the day
  # loop fans out cleanly over schedulers via `Task.async_stream`. The shared
  # SPK ETS table is read-concurrent and the almanac path uses the telemetry-
  # free, GenServer-free query, so the tasks never serialize on a process.
  defp events_for_day(day_idx, start_dt, stop_dt, observer, bodies, lat, lon) do
    day_start = DateTime.add(start_dt, day_idx * 86_400, :second)
    noon = DateTime.add(day_start, 43_200, :second)
    noon_frame = ApparentPlace.frame(noon, observer)
    nutation = noon_frame.nutation
    velocity = noon_frame.earth_velocity_km_per_day

    Enum.flat_map(bodies, fn body ->
      noon_look = ApparentPlace.look(noon_frame, body)
      seeds = analytic_seeds(noon_look, noon_frame, lat, lon)

      find_events_from_seeds(
        body,
        seeds,
        day_start,
        observer,
        nutation,
        velocity,
        start_dt,
        stop_dt
      )
    end)
  end

  @doc """
  Convenience wrapper returning `%{meta: ..., events: ...}` matching SPEC §6.

  ## Options
  - `:year` (default `2026`), `:bodies` (atoms or a preset atom, default `:classic8`),
    `:observer` (default Chicago at 181 m), `:kernel` (label only, default
    `"de440s.bsp"`), plus any `events/4` options.
  """
  @spec generate(keyword()) :: %{meta: map(), events: [event()]}
  def generate(opts \\ []) do
    year = Keyword.get(opts, :year, 2026)
    observer = Keyword.get(opts, :observer, chicago())
    bodies = resolve_bodies(Keyword.get(opts, :bodies, :classic8))
    kernel = Keyword.get(opts, :kernel, "de440s.bsp")
    {start_dt, stop_dt} = span(year)

    events = events(observer, year, bodies, opts)

    meta = %{
      engine: "eph_core",
      kernel: kernel,
      generated_utc:
        DateTime.utc_now()
        |> DateTime.truncate(:second)
        |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ"),
      year: year,
      span_utc: %{
        start: Calendar.strftime(start_dt, "%Y-%m-%dT%H:%M:%SZ"),
        end: Calendar.strftime(stop_dt, "%Y-%m-%dT%H:%M:%SZ")
      },
      location: %{
        latitude_deg: observer[:lat],
        longitude_deg: observer[:lon],
        elevation_m: observer[:height] || observer[:elevation] || 0.0
      },
      bodies: Enum.map(bodies, &Atom.to_string/1),
      horizon_convention: "usno",
      event_count: length(events)
    }

    %{meta: meta, events: events}
  end

  @doc "Example observer at Chicago (41.8781°N, 87.6298°W, 181 m elevation)."
  @spec chicago() :: observer()
  def chicago, do: %{lat: 41.8781, lon: -87.6298, height: 181.0}

  @doc false
  def resolve_bodies(spec) when is_atom(spec), do: preset(spec)
  def resolve_bodies(spec) when is_list(spec), do: spec

  # ---------------------------------------------------------------------------
  # Analytic seeds (Meeus closed-form hour-angle)
  # ---------------------------------------------------------------------------

  # From a single noon look, predict approximate UTC times for rise, transit,
  # and set using the spherical-trig hour-angle formula. Returns a list of
  # `{:rise | :transit | :set, seed_utc_offset_seconds}` where the offset is
  # relative to the day's 00:00 UTC.
  defp analytic_seeds(noon_look, noon_frame, lat_deg, lon_deg) do
    dec_rad = Angle.deg_to_rad(noon_look.declination_deg)
    lat_rad = Angle.deg_to_rad(lat_deg)
    ra_deg = ra_from_look(noon_look, noon_frame)

    # GAST at the day's 00:00 UTC — derive from noon LAST by subtracting
    # 12 hours of sidereal rotation and the observer longitude.
    gast_noon_deg = noon_frame.last_deg - lon_deg
    gast_0h_deg = Angle.normalize_360(gast_noon_deg - 12.0 * 15.0 * @sidereal_rate)

    cos_h0 = -:math.tan(lat_rad) * :math.tan(dec_rad)

    transit_seed = transit_utc_offset(ra_deg, lon_deg, gast_0h_deg)

    cond do
      cos_h0 > 1.0 ->
        # Never rises — no events (not even transit for the diff to match)
        []

      cos_h0 < -1.0 ->
        # Circumpolar — transit only
        [{:transit, transit_seed}]

      true ->
        h0_deg = Angle.rad_to_deg(:math.acos(cos_h0))
        rise_lst = Angle.normalize_360(ra_deg - h0_deg)
        set_lst = Angle.normalize_360(ra_deg + h0_deg)

        rise_seed = lst_to_utc_offset(rise_lst, lon_deg, gast_0h_deg)
        set_seed = lst_to_utc_offset(set_lst, lon_deg, gast_0h_deg)

        [{:rise, rise_seed}, {:transit, transit_seed}, {:set, set_seed}]
    end
  end

  # Recover RA from the look's hour_angle and the frame's LAST.
  defp ra_from_look(look, frame) do
    Angle.normalize_360(frame.last_deg - look.hour_angle_deg)
  end

  defp transit_utc_offset(ra_deg, lon_deg, gast_0h_deg) do
    gast_deg = Angle.normalize_360(ra_deg)
    lst_to_utc_offset(gast_deg, lon_deg, gast_0h_deg)
  end

  defp lst_to_utc_offset(lst_deg, lon_deg, gast_0h_deg) do
    gast_deg = Angle.normalize_360(lst_deg - lon_deg)
    delta_deg = Angle.normalize_360(gast_deg - gast_0h_deg)
    delta_deg / (15.0 * @sidereal_rate) * 3600.0
  end

  # ---------------------------------------------------------------------------
  # Bracket confirmation + event extraction
  # ---------------------------------------------------------------------------

  defp find_events_from_seeds(
         body,
         seeds,
         day_start,
         observer,
         nutation,
         velocity,
         start_dt,
         stop_dt
       ) do
    bracket_sec = @bracket_minutes * 60

    value_at = fn utc ->
      frame = ApparentPlace.frame(utc, observer, nutation: nutation, earth_velocity: velocity)
      look = ApparentPlace.look(frame, body)
      {frame, look}
    end

    seeds
    |> Enum.flat_map(fn {kind, offset_sec} ->
      candidate_offsets(offset_sec, bracket_sec)
      |> Enum.flat_map(fn offset_sec ->
        seed_utc = DateTime.add(day_start, round(offset_sec), :second)
        t_lo = DateTime.add(seed_utc, -bracket_sec, :second)
        t_hi = DateTime.add(seed_utc, bracket_sec, :second)

        residual_fun = if kind == :transit, do: &hour_angle_residual/2, else: &altitude_residual/2

        {_f_lo, l_lo} = value_at.(t_lo)
        {_f_hi, l_hi} = value_at.(t_hi)

        r_lo = residual_fun.(l_lo, body)
        r_hi = residual_fun.(l_hi, body)

        cond do
          # Transit: HA wraps through ±180; only accept negative→positive crossing
          kind == :transit and r_lo < 0.0 and r_hi >= 0.0 ->
            [
              refine_event(
                body,
                kind,
                t_lo,
                t_hi,
                r_lo,
                r_hi,
                observer,
                nutation,
                velocity,
                residual_fun
              )
            ]

          # Rise/set: confirm sign change in the expected direction
          kind == :rise and r_lo < 0.0 and r_hi >= 0.0 ->
            [
              refine_event(
                body,
                kind,
                t_lo,
                t_hi,
                r_lo,
                r_hi,
                observer,
                nutation,
                velocity,
                residual_fun
              )
            ]

          kind == :set and r_lo >= 0.0 and r_hi < 0.0 ->
            [
              refine_event(
                body,
                kind,
                t_lo,
                t_hi,
                r_lo,
                r_hi,
                observer,
                nutation,
                velocity,
                residual_fun
              )
            ]

          # Bracket didn't confirm — the seed was off (Moon's fast motion, or
          # near-horizon grazing). Fall back to a fine sweep of the bracket.
          kind != :transit and not same_sign?(r_lo, r_hi) ->
            actual_kind = if r_lo < 0.0, do: :rise, else: :set

            [
              refine_event(
                body,
                actual_kind,
                t_lo,
                t_hi,
                r_lo,
                r_hi,
                observer,
                nutation,
                velocity,
                &altitude_residual/2
              )
            ]

          true ->
            []
        end
      end)
    end)
    |> Enum.filter(&in_span?(&1, start_dt, stop_dt))
  end

  # A sidereal day is ~4 minutes shorter than a UTC day. For slow-moving bodies
  # this means the same kind of event can occur just after midnight and again
  # just before midnight on the same UTC date. The old dense grid saw those
  # naturally; the analytic seed only needs adjacent-cycle probes when the
  # predicted event is close enough to a UTC boundary for the neighbor cycle's
  # bracket to overlap the current year/day.
  defp candidate_offsets(offset_sec, bracket_sec) do
    boundary_slack = bracket_sec + (86_400.0 - @sidereal_day_seconds)

    []
    |> maybe_prepend(offset_sec - @sidereal_day_seconds, offset_sec > 86_400.0 - boundary_slack)
    |> Kernel.++([offset_sec])
    |> Kernel.++(
      if offset_sec < boundary_slack, do: [offset_sec + @sidereal_day_seconds], else: []
    )
  end

  defp maybe_prepend(list, value, true), do: [value | list]
  defp maybe_prepend(list, _value, false), do: list

  # Residual functions
  defp altitude_residual(look, body),
    do: look.alt_deg - horizon_threshold_deg(body, look.range_km)

  defp hour_angle_residual(look, _body), do: look.hour_angle_deg

  # ---------------------------------------------------------------------------
  # Bracketed interpolation refinement
  # ---------------------------------------------------------------------------

  defp refine_event(
         body,
         kind,
         t_lo,
         t_hi,
         r_lo,
         r_hi,
         observer,
         nutation,
         velocity,
         residual_fun
       ) do
    value_at = fn utc ->
      frame = ApparentPlace.frame(utc, observer, nutation: nutation, earth_velocity: velocity)
      look = ApparentPlace.look(frame, body)
      {residual_fun.(look, body), frame, look}
    end

    precise_utc = solve_bracket(t_lo, t_hi, r_lo, r_hi, value_at, 0)
    build_event(body, kind, precise_utc, value_at)
  end

  defp solve_bracket(a, b, fa, fb, value_at, iter) do
    if DateTime.diff(b, a, :microsecond) <= @refine_tolerance_us or iter >= @max_refine_iterations do
      midpoint(a, b)
    else
      m = interpolated_time(a, b, fa, fb)
      {fm, _, _} = value_at.(m)

      if same_sign?(fa, fm),
        do: solve_bracket(m, b, fm, fb, value_at, iter + 1),
        else: solve_bracket(a, m, fa, fm, value_at, iter + 1)
    end
  end

  defp midpoint(a, b),
    do: DateTime.add(a, div(DateTime.diff(b, a, :microsecond), 2), :microsecond)

  defp interpolated_time(a, b, fa, fb) do
    width_us = DateTime.diff(b, a, :microsecond)

    frac =
      if fa == fb do
        0.5
      else
        fa / (fa - fb)
      end
      |> min(0.9)
      |> max(0.1)

    DateTime.add(a, round(width_us * frac), :microsecond)
  end

  defp same_sign?(x, y), do: x >= 0.0 == y >= 0.0

  defp build_event(body, kind, precise_utc, value_at) do
    {_residual, frame, look} = value_at.(precise_utc)

    base = %{
      body: Atom.to_string(body),
      event: Atom.to_string(kind),
      utc: Calendar.strftime(DateTime.truncate(precise_utc, :second), "%Y-%m-%dT%H:%M:%SZ"),
      tt_jd: frame.jd_tt,
      az_deg: Float.round(look.az_deg, 3)
    }

    if kind == :transit, do: Map.put(base, :alt_deg, Float.round(look.alt_deg, 3)), else: base
  end

  defp in_span?(%{utc: utc}, start_dt, stop_dt) do
    {:ok, dt, _} = DateTime.from_iso8601(utc)
    DateTime.compare(dt, start_dt) != :lt and DateTime.compare(dt, stop_dt) == :lt
  end

  defp dedupe_close_events(events) do
    events
    |> Enum.group_by(fn e -> {e.body, e.event} end)
    |> Enum.flat_map(fn {_key, group} ->
      group
      |> Enum.sort_by(& &1.tt_jd)
      |> Enum.reduce([], fn event, acc ->
        case acc do
          [prev | rest] when (event.tt_jd - prev.tt_jd) * 86_400.0 < 6.0 * 3600.0 ->
            [prev | rest]

          _ ->
            [event | acc]
        end
      end)
    end)
  end
end
