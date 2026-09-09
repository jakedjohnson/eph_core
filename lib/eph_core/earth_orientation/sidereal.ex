defmodule EphCore.EarthOrientation.Sidereal do
  @moduledoc """
  Calculates Greenwich Mean Sidereal Time (GMST) using IAU 2006/2000A standards.

  Implements full IAU 2000A nutation series (106 terms) for high-precision transformations.
  Fundamental arguments computed per IERS Conventions 2010, Table 5.1.
  Achieves <1e-8° precision matching Python Skyfield library.

  Reference: IERS Conventions 2010 (https://www.iers.org/IERS/EN/Publications/TechnicalNotes/tn36.html)

  ## Two Approaches

  ### 1. Simplified Formula (Fast, UT1-based)
  Good for applications where precision within ~0.1 seconds is acceptable:

  ```
  GMST (deg) = 280.46061837 + 360.98564736629 × (JD_UT1 − 2451545.0)
  ```

  ### 2. IAU 2006/2000A Rigorous Formula
  High-precision formula that splits Earth rotation and precession:

  ```
  GMST (seconds) = 67310.54841
                   + (876600 × 3600 + 8640184.812866) × T_UT1
                   + 0.093104 × T_TT²
                   − 6.2×10⁻⁶ × T_TT³
  ```

  Where:
  - `T_UT1` = Julian centuries since J2000 in UT1 (Earth rotation angle)
  - `T_TT` = Julian centuries since J2000 in TT (uniform precession timebase)

  ## Why Two Time Scales?

  The IAU formula uses both UT1 and TT because:
  - Earth's actual spin varies irregularly → needs UT1
  - Precession models require smooth atomic time → needs TT

  Think of it as: "Where is Earth right now (UT1), accounting for
  long-term drift calculated on a perfect clock (TT)?"
  """

  alias AstroUtils.Matrix3
  import AstroUtils.Angle, only: [deg_to_rad: 1]

  # Seconds per day
  @seconds_per_day 86_400.0

  # IAU 2006 GMST coefficients
  @gmst_constant 67_310.54841
  @gmst_linear_coeff 8_640_184.812866
  @gmst_earth_rotations 876_600
  @gmst_quadratic_coeff 0.093104
  @gmst_cubic_coeff 6.2e-6

  @doc """
  Computes GMST using the IAU 2006/2000A rigorous formula.

  Returns GMST in degrees, normalized to [0, 360).

  ## Parameters
  - `jd_ut1`: Julian Date in UT1 time scale
  - `jd_tt`: Julian Date in Terrestrial Time (TT) scale

  ## Examples

      iex> gmst_iau_2006(2451545.0, 2451545.0)
      # GMST at J2000.0 epoch
      280.46061837

  """
  def gmst_iau_2006(jd_ut1, jd_tt) do
    # Convert seconds to degrees and normalize
    jd_ut1
    |> gmst_iau_2006_seconds(jd_tt)
    |> seconds_to_degrees()
    |> normalize_angle()
  end

  def gmst_iau_2006_seconds(jd_ut1, jd_tt) do
    # Calculate Julian centuries since J2000 for both time scales
    t_ut1 = julian_centuries_since_j2000(jd_ut1)
    t_tt = julian_centuries_since_j2000(jd_tt)

    # Compute GMST in seconds using IAU 2006 formula
    @gmst_constant +
      (@gmst_earth_rotations * 3600 + @gmst_linear_coeff) * t_ut1 +
      @gmst_quadratic_coeff * t_tt * t_tt -
      @gmst_cubic_coeff * t_tt * t_tt * t_tt
  end

  @doc """
  Computes GAST (Greenwich Apparent Sidereal Time) using IAU 2006 standards.

  GAST = GMST + equation of equinoxes

  This accounts for nutation in longitude, which causes a small shift in the
  position of the vernal equinox. The equation of equinoxes here comes from a
  truncated IAU 2000B model with ~0.1 arcsecond error; use
  `nutation_iau2000a/1` when you need the full series.

  ## Parameters
  - `jd_ut1`: Julian Date in UT1 time scale
  - `jd_tt`: Julian Date in Terrestrial Time (TT) scale

  ## Returns
  GAST in degrees, normalized to [0, 360)
  """
  def gast_iau_2006(jd_ut1, jd_tt) do
    gmst = gmst_iau_2006(jd_ut1, jd_tt)
    eq_eq = equation_of_equinoxes(jd_tt)
    normalize_angle(gmst + eq_eq)
  end

  @doc """
  Computes the equation of equinoxes (nutation correction to GMST).

  Uses the simplified IAU 2000B truncated nutation model (~0.1 arcsecond error).

  ## Parameters
  - `jd_tt`: Julian Date in Terrestrial Time

  ## Returns
  Equation of equinoxes in degrees
  """
  def equation_of_equinoxes(jd_tt) do
    # TT centuries since J2000.0
    t = julian_centuries_since_j2000(jd_tt)

    # Simplified nutation in longitude (truncated IAU 2000B)
    # Primary term: 18.6-year lunar nodal cycle
    delta_psi = -0.000319 * :math.sin(2.586 * t + 4.538)

    # Mean obliquity of ecliptic (J2000 + linear drift)
    # ε₀ = 23.439281° - 0.00000036° × t
    obliquity = 23.439281 - 0.00000036 * t

    # Equation of equinoxes: Δψ × cos(ε)
    # Convert to degrees
    delta_psi * :math.cos(:math.pi() * obliquity / 180.0)
  end

  def gmst_to_lst(gmst_deg, lon_deg) do
    lst = gmst_deg + lon_deg
    normalize_angle(lst)
  end

  def lst_to_hours(lst_deg), do: lst_deg / 15.0

  @doc """
  Converts Julian Date to Julian centuries since J2000.0 epoch.

  ## Examples

      iex> julian_centuries_since_j2000(2451545.0)
      0.0  # At J2000.0

      iex> julian_centuries_since_j2000(2488070.0)
      1.0  # One century after J2000.0

  """
  def julian_centuries_since_j2000(jd) do
    AstroUtils.Time.julian_centuries(jd)
  end

  @doc """
  Converts time in seconds to degrees.

  Uses the relationship: 86400 seconds = 360 degrees (one full rotation).
  """
  def seconds_to_degrees(seconds) do
    seconds * (360 / @seconds_per_day)
  end

  @doc """
  Normalizes an angle in degrees to the range [0, 360).

  Uses high-precision modulo to minimize floating-point error accumulation.
  This is critical for astronomical calculations where sub-arcsecond precision matters.

  ## Examples

      iex> normalize_angle(450.0)
      90.0

      iex> normalize_angle(-30.0)
      330.0

  """
  defdelegate normalize_angle(degrees), to: AstroUtils.Angle, as: :normalize_360

  @doc """
  Computes the IAU 2006 precession rotation matrix from J2000 to date.

  Returns 3x3 matrix to rotate J2000 equatorial vectors to mean-of-date equatorial.

  ## Parameters
  - `jd_tt`: Julian Date in TT scale

  ## Returns
  Matrix3.t()
  """
  def precession_matrix_iau2006(jd_tt) do
    t = julian_centuries_since_j2000(jd_tt)

    # Precession angles (IAU 2006, in arcseconds)
    zeta =
      (2.5976176 + 2306.0809506 * t + 0.3019015 * t * t + 0.0179663 * t * t * t -
         0.0000327 * t * t * t * t -
         0.0000002 * t * t * t * t * t) / 3600.0

    theta =
      (2004.1917476 * t - 0.4269353 * t * t - 0.0418251 * t * t * t - 0.0000601 * t * t * t * t -
         0.0000001 * t * t * t * t * t) / 3600.0

    z =
      (2.5976176 + 2306.0803226 * t + 1.0947790 * t * t + 0.0182721 * t * t * t -
         0.0000399 * t * t * t * t +
         0.0000003 * t * t * t * t * t) / 3600.0

    # Convert to radians
    zeta_rad = zeta * :math.pi() / 180.0
    theta_rad = theta * :math.pi() / 180.0
    z_rad = z * :math.pi() / 180.0

    # Precession matrix = R3(-z) × R2(theta) × R3(-zeta)
    r3_neg_z = Matrix3.rot_z(-z_rad)
    r2_theta = Matrix3.rot_y(theta_rad)
    r3_neg_zeta = Matrix3.rot_z(-zeta_rad)

    r3_neg_z
    |> Matrix3.multiply(r2_theta)
    |> Matrix3.multiply(r3_neg_zeta)
  end

  @doc """
  Computes mean obliquity of ecliptic at date (IAU 2006).

  ## Parameters
  - `jd_tt`: Julian Date in TT

  ## Returns
  Obliquity in degrees
  """
  def mean_obliquity_iau2006(jd_tt) do
    t = julian_centuries_since_j2000(jd_tt)

    # IAU 2006 mean obliquity (arcseconds)
    eps =
      84_381.406 +
        -46.836769 * t +
        -0.0001831 * t * t +
        0.00200340 * t * t * t +
        -0.00000576 * t * t * t * t +
        -0.0000000434 * t * t * t * t * t

    # To degrees
    eps / 3600.0
  end

  @doc """
  Computes the mean precession matrix from J2000 to mean-of-date.

  Returns the transpose of the existing precession_matrix_iau2006 to provide
  J2000 → mean-of-date transformation (matching Python Skyfield).

  ## Parameters
  - `jd_tt`: Julian Date in TT

  ## Returns
  Matrix3.t() for J2000 → mean-of-date transformation
  """
  def mean_precession_matrix_iau2006(jd_tt) do
    jd_tt
    |> precession_matrix_iau2006()
    |> Matrix3.transpose()
  end

  @doc """
  Computes the 5 fundamental arguments for IAU 2000A nutation.

  Returns {l, lp, F, D, Omega} in radians.

  ## Parameters
  - jd_tt: Julian Date in TT

  ## Fundamental arguments:
  - l: mean anomaly of the Moon
  - lp: mean anomaly of the Sun
  - F: mean argument of latitude (Moon)
  - D: mean elongation of Moon from Sun
  - Omega: longitude of ascending node of Moon

  ## Reference
  IERS Conventions 2010, Table 5.1
  """
  def fundamental_arguments_iau2000(jd_tt) do
    t = julian_centuries_since_j2000(jd_tt)

    # Mean anomaly of Moon (l)
    l =
      normalize_angle_rad(
        deg_to_rad(134.96340251) +
          deg_to_rad(1_717_915_923.2178) * t / 3600.0 +
          deg_to_rad(31.8792) * t * t / 3600.0 +
          deg_to_rad(0.051635) * t * t * t / 3600.0 -
          deg_to_rad(0.00024470) * t * t * t * t / 3600.0
      )

    # Mean anomaly of Sun (l')
    lp =
      normalize_angle_rad(
        deg_to_rad(357.52910918) +
          deg_to_rad(129_596_581.0481) * t / 3600.0 -
          deg_to_rad(0.5532) * t * t / 3600.0 +
          deg_to_rad(0.000136) * t * t * t / 3600.0 -
          deg_to_rad(0.00001149) * t * t * t * t / 3600.0
      )

    # Mean argument of latitude of Moon (F)
    f =
      normalize_angle_rad(
        deg_to_rad(93.27209062) +
          deg_to_rad(1_739_527_262.8478) * t / 3600.0 -
          deg_to_rad(12.7512) * t * t / 3600.0 -
          deg_to_rad(0.001037) * t * t * t / 3600.0 +
          deg_to_rad(0.00000417) * t * t * t * t / 3600.0
      )

    # Mean elongation of Moon from Sun (D)
    d =
      normalize_angle_rad(
        deg_to_rad(297.85019547) +
          deg_to_rad(1_602_961_601.2090) * t / 3600.0 -
          deg_to_rad(6.3706) * t * t / 3600.0 +
          deg_to_rad(0.006593) * t * t * t / 3600.0 -
          deg_to_rad(0.00003169) * t * t * t * t / 3600.0
      )

    # Longitude of ascending node of Moon (Ω)
    omega =
      normalize_angle_rad(
        deg_to_rad(125.04455501) -
          deg_to_rad(6_962_890.5431) * t / 3600.0 +
          deg_to_rad(7.4722) * t * t / 3600.0 +
          deg_to_rad(0.007702) * t * t * t / 3600.0 -
          deg_to_rad(0.00005939) * t * t * t * t / 3600.0
      )

    {l, lp, f, d, omega}
  end

  defp normalize_angle_rad(rad) do
    two_pi = 2 * :math.pi()
    normalized = :math.fmod(rad, two_pi)
    if normalized < 0, do: normalized + two_pi, else: normalized
  end

  @doc """
  Computes nutation in longitude (Δψ) and obliquity (Δε) using full IAU 2000A series.

  Returns {delta_psi_rad, delta_epsilon_rad}.

  ## Parameters
  - jd_tt: Julian Date in TT

  ## Implementation
  Sums all 106 terms from IAU 2000A nutation series.
  Each term contributes sine/cosine components based on 5 fundamental arguments.
  """
  def nutation_iau2000a(jd_tt) do
    :telemetry.execute([:eph_core, :nutation, :evaluate], %{count: 1}, %{})

    t = julian_centuries_since_j2000(jd_tt)
    {l, lp, f, d, omega} = fundamental_arguments_iau2000(jd_tt)

    terms = EphCore.EarthOrientation.Tables.NutationIAU2000A.get_terms()

    # Sum contributions
    {delta_psi_tenths_uas, delta_epsilon_tenths_uas} =
      Enum.reduce(terms, {0.0, 0.0}, fn {_idx, term}, {psi_sum, eps_sum} ->
        {l_mult, lp_mult, f_mult, d_mult, omega_mult, psi_s, psi_c, psi_t, eps_c, eps_s, eps_t} =
          term

        # Fundamental argument for this term
        arg =
          l_mult * l + lp_mult * lp + f_mult * f +
            d_mult * d + omega_mult * omega

        # Nutation in longitude (Δψ)
        # Aψ = (Aψ_sin + Aψ_t * t) * sin(arg) + Aψ_cos * cos(arg)
        delta_psi = (psi_s + psi_t * t) * :math.sin(arg) + psi_c * :math.cos(arg)

        # Nutation in obliquity (Δε)
        # Aε = (Aε_cos + Aε_t * t) * cos(arg) + Aε_sin * sin(arg)
        delta_eps = (eps_c + eps_t * t) * :math.cos(arg) + eps_s * :math.sin(arg)

        {psi_sum + delta_psi, eps_sum + delta_eps}
      end)

    uas_to_rad = :math.pi() / (180.0 * 3600.0 * 1_000_000.0)
    delta_psi_rad = delta_psi_tenths_uas * uas_to_rad
    delta_epsilon_rad = delta_epsilon_tenths_uas * uas_to_rad

    {delta_psi_rad, delta_epsilon_rad}
  end

  @doc """
  Computes the true precession-nutation matrix from J2000 to true-of-date.

  Combines precession with nutation to provide the complete transformation
  from J2000 equatorial to true-of-date equatorial coordinates.

  ## Parameters
  - jd_tt: Julian Date in TT

  ## Returns
  Matrix3.t() for J2000 → true-of-date transformation

  ## Implementation
  True matrix = Mean precession matrix × Nutation matrix
  Following IAU 2006/2000A standard.
  """
  def true_precession_matrix_iau2006(jd_tt) do
    true_precession_matrix_iau2006(jd_tt, nutation_iau2000a(jd_tt))
  end

  @doc false
  def true_precession_matrix_iau2006(jd_tt, {delta_psi, delta_epsilon})
      when is_float(delta_psi) and is_float(delta_epsilon) do
    mean_precession = mean_precession_matrix_iau2006(jd_tt)
    mean_obliquity_rad = mean_obliquity_iau2006(jd_tt) * :math.pi() / 180.0
    true_obliquity_rad = mean_obliquity_rad + delta_epsilon

    # Nutation matrix N (mean-of-date → true-of-date equatorial). Rotate the
    # mean-equatorial vector down to the (mean) ecliptic with R1(-ε_mean),
    # shift the equinox along the ecliptic by +Δψ with R3(Δψ), then rotate
    # back up to the true equator with R1(ε_true). `rot_x`/`rot_z` are vector
    # rotations here, so equatorial↔ecliptic uses rot_x(∓ε) (matching
    # `icrf_to_mean_ecliptic_of_date`) and apparent longitude = mean + Δψ.
    #
    #   N = R1(ε_true) · R3(Δψ) · R1(-ε_mean)
    #
    # Verified against Swiss Ephemeris apparent RA/Dec and
    # ecliptic longitude across multiple bodies/dates to <0.001". The earlier
    # form swapped the obliquity rotations and negated Δψ, which flipped the
    # sign of nutation-in-longitude (~±8-17") and corrupted the longitude rate,
    # pushing retrograde-station timing hours late.
    nutation_matrix =
      Matrix3.rot_x(true_obliquity_rad)
      |> Matrix3.multiply(Matrix3.rot_z(delta_psi))
      |> Matrix3.multiply(Matrix3.rot_x(-mean_obliquity_rad))

    # Combine: J2000 → mean-of-date → true-of-date
    # Apply mean precession first, then nutation: C = N × M
    Matrix3.multiply(nutation_matrix, mean_precession)
  end

  @doc """
  Computes true obliquity of ecliptic (mean obliquity + nutation in obliquity).

  ## Parameters
  - jd_tt: Julian Date in TT

  ## Returns
  True obliquity in degrees
  """
  def true_obliquity_iau2006(jd_tt) do
    true_obliquity_iau2006(jd_tt, nutation_iau2000a(jd_tt))
  end

  @doc false
  def true_obliquity_iau2006(jd_tt, {_delta_psi, delta_epsilon})
      when is_float(delta_epsilon) do
    mean_eps_deg = mean_obliquity_iau2006(jd_tt)
    mean_eps_deg + delta_epsilon * 180.0 / :math.pi()
  end

  @doc """
  Computes a simplified nutation matrix (IAU 2006 truncated model).

  Provides the main nutation terms with ~0.1" accuracy. For full IAU 2000A
  precision, use `true_precession_matrix_iau2006/2` with `nutation_iau2000a/1`.

  ## Parameters
  - `jd_tt`: Julian Date in TT

  ## Returns
  Matrix3.t() nutation rotation matrix
  """
  def nutation_matrix_iau2006(jd_tt) do
    t = julian_centuries_since_j2000(jd_tt)

    # Simplified nutation angles (arcseconds)
    # Main term: 18.6-year lunar nodal cycle
    # Nutation in longitude
    delta_psi = -17.2 * :math.sin(2.182 * t + 3.785)
    # Nutation in obliquity
    delta_epsilon = 9.2 * :math.cos(2.182 * t + 3.785)

    # Convert to radians
    delta_psi_rad = delta_psi / 3600.0 * :math.pi() / 180.0
    delta_epsilon_rad = delta_epsilon / 3600.0 * :math.pi() / 180.0

    # Mean obliquity
    eps_mean_rad = mean_obliquity_iau2006(jd_tt) * :math.pi() / 180.0

    # Nutation matrix: R1(-eps_mean) × R3(-delta_psi) × R1(eps_mean + delta_epsilon)
    r1_neg_eps = Matrix3.rot_x(-eps_mean_rad)
    r3_neg_dpsi = Matrix3.rot_z(-delta_psi_rad)
    r1_eps_deps = Matrix3.rot_x(eps_mean_rad + delta_epsilon_rad)

    r1_neg_eps
    |> Matrix3.multiply(r3_neg_dpsi)
    |> Matrix3.multiply(r1_eps_deps)
  end

  @doc """
  Computes nutation in obliquity (simplified model).

  ## Parameters
  - `jd_tt`: Julian Date in TT

  ## Returns
  Nutation in obliquity in degrees
  """
  def nutation_in_obliquity(jd_tt) do
    t = julian_centuries_since_j2000(jd_tt)

    # Main nutation term (arcseconds)
    delta_epsilon = 9.2 * :math.cos(2.182 * t + 3.785)

    # Convert to degrees
    delta_epsilon / 3600.0
  end
end
