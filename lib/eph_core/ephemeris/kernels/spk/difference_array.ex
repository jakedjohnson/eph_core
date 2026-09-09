defmodule EphCore.Ephemeris.Kernels.SPK.DifferenceArray do
  @moduledoc """
  Evaluates an SPK Type 21 (Extended Modified Difference Array) record.

  This is a pure-Elixir transliteration of the SPICELIB `spke21.f` routine
  (Fred Krogh's DAINT algorithm). The Python reference implementation is
  whiskie14142/spktype21, which itself was translated from the FORTRAN source.

  ## Algorithm overview

  Given a reference epoch TL and query epoch ET, the algorithm evaluates
  position and velocity by:

  1. Computing delta = ET - TL.
  2. Building the FC (forward-coefficient) and WC (weight-coefficient) arrays
     from the stepsize vector G.
  3. Seeding W with reciprocals: W[j] = 1/(j+1).
  4. Evolving W via a KS-loop until KS = 1 (position phase).
  5. Performing position interpolation: P = REFPOS + Δ * (REFVEL + Δ * Σ DT·W).
  6. Evolving W one more step to KS = 0 (velocity phase).
  7. Performing velocity interpolation: V = REFVEL + Δ * Σ DT·W.

  All indices below follow Python 0-based convention; the comments show the
  original Fortran 1-based names for cross-reference.
  """

  @spec evaluate(map(), float()) ::
          {:ok, {float(), float(), float(), float(), float(), float()}}
          | {:error, term()}
  def evaluate(record, et) do
    %{
      tl: tl,
      g: g,
      refpos: {rx, ry, rz},
      refvel: {vx, vy, vz},
      dt: {dt_x, dt_y, dt_z},
      kqmax1: kqmax1,
      kq: {kq_x, kq_y, kq_z}
    } = record

    delta = et - tl
    mq2 = kqmax1 - 2
    ks0 = kqmax1 - 1

    # Build FC and WC from the stepsize vector G.
    # FC[J] and WC[J-1] for J = 1..MQ2 (both 0-indexed maps here).
    {fc, wc} = build_fc_wc(g, mq2, delta)

    # Seed W: W[j] = 1/(j+1) for j = 0..KQMAX1-1  (Fortran: W(J) = 1/J)
    w_seed =
      if kqmax1 > 0 do
        Enum.reduce(0..(kqmax1 - 1), %{}, fn j, acc ->
          Map.put(acc, j, 1.0 / (j + 1.0))
        end)
      else
        %{}
      end

    # Evolve W until KS < 2 (position phase). Returns {w, jx, ks_pos}.
    {w_pos, jx, ks_pos} = evolve_w(w_seed, fc, wc, ks0, 0)

    # Position interpolation.
    pos_x = interp_pos(dt_x, kq_x, ks_pos, w_pos, delta, rx, vx)
    pos_y = interp_pos(dt_y, kq_y, ks_pos, w_pos, delta, ry, vy)
    pos_z = interp_pos(dt_z, kq_z, ks_pos, w_pos, delta, rz, vz)

    # Evolve W one final step for velocity phase.
    # At this point KS_pos = 1, KS1 = 0.
    {w_vel, ks_vel} = evolve_w_one_step(w_pos, fc, wc, jx, ks_pos)

    # Velocity interpolation.
    vel_x = interp_vel(dt_x, kq_x, ks_vel, w_vel, delta, vx)
    vel_y = interp_vel(dt_y, kq_y, ks_vel, w_vel, delta, vy)
    vel_z = interp_vel(dt_z, kq_z, ks_vel, w_vel, delta, vz)

    {:ok, {pos_x, pos_y, pos_z, vel_x, vel_y, vel_z}}
  rescue
    e -> {:error, e}
  end

  # -----------------------------------------------------------------------
  # FC / WC construction
  # -----------------------------------------------------------------------

  # FC[J] = TP / G[J-1]; WC[J-1] = DELTA / G[J-1]; TP = DELTA + G[J-1]
  # for J = 1..MQ2 (0-indexed map keys).
  defp build_fc_wc(_g, mq2, _delta) when mq2 <= 0, do: {%{}, %{}}

  defp build_fc_wc(g, mq2, delta) do
    {fc, wc, _tp} =
      Enum.reduce(1..mq2, {%{}, %{}, delta}, fn j, {fc, wc, tp} ->
        g_j = Enum.at(g, j - 1, 0.0)

        if g_j == 0.0 do
          raise RuntimeError, "zero stepsize at G[#{j - 1}] in Type 21 MDA record"
        end

        {Map.put(fc, j, tp / g_j), Map.put(wc, j - 1, delta / g_j), delta + g_j}
      end)

    {fc, wc}
  end

  # -----------------------------------------------------------------------
  # W evolution (KS-loop)
  # -----------------------------------------------------------------------

  # Base case: KS < 2, nothing more to do.
  defp evolve_w(w, _fc, _wc, ks, jx) when ks < 2, do: {w, jx, ks}

  defp evolve_w(w, fc, wc, ks, jx) do
    jx_new = jx + 1
    ks1 = ks - 1

    # For J = 1..JX_new:
    #   W[J + KS - 1] = FC[J] * W[J + KS1 - 1] - WC[J-1] * W[J + KS - 1]
    w_new =
      Enum.reduce(1..jx_new, w, fn j, w_acc ->
        write_key = j + ks - 1
        read_key = j + ks1 - 1

        val =
          Map.get(fc, j, 0.0) * Map.get(w_acc, read_key, 0.0) -
            Map.get(wc, j - 1, 0.0) * Map.get(w_acc, write_key, 0.0)

        Map.put(w_acc, write_key, val)
      end)

    evolve_w(w_new, fc, wc, ks1, jx_new)
  end

  # One more W step for velocity (KS goes from 1 → 0).
  defp evolve_w_one_step(w, _fc, _wc, 0, ks), do: {w, ks - 1}

  defp evolve_w_one_step(w, fc, wc, jx, ks) do
    ks1 = ks - 1

    w_new =
      Enum.reduce(1..jx, w, fn j, w_acc ->
        write_key = j + ks - 1
        read_key = j + ks1 - 1

        val =
          Map.get(fc, j, 0.0) * Map.get(w_acc, read_key, 0.0) -
            Map.get(wc, j - 1, 0.0) * Map.get(w_acc, write_key, 0.0)

        Map.put(w_acc, write_key, val)
      end)

    {w_new, ks1}
  end

  # -----------------------------------------------------------------------
  # Interpolation
  # -----------------------------------------------------------------------

  # Position: STATE[i] = REFPOS + Δ * (REFVEL + Δ * Σ_{J=KQQ..1} DT[J-1] * W[J+KS-1])
  defp interp_pos(dt, kqq, ks, w, delta, refpos, refvel) do
    sum =
      if kqq > 0 do
        Enum.reduce(kqq..1//-1, 0.0, fn j, acc ->
          acc + Enum.at(dt, j - 1, 0.0) * Map.get(w, j + ks - 1, 0.0)
        end)
      else
        0.0
      end

    refpos + delta * (refvel + delta * sum)
  end

  # Velocity: STATE[i+3] = REFVEL + Δ * Σ_{J=KQQ..1} DT[J-1] * W[J+KS-1]
  defp interp_vel(dt, kqq, ks, w, delta, refvel) do
    sum =
      if kqq > 0 do
        Enum.reduce(kqq..1//-1, 0.0, fn j, acc ->
          acc + Enum.at(dt, j - 1, 0.0) * Map.get(w, j + ks - 1, 0.0)
        end)
      else
        0.0
      end

    refvel + delta * sum
  end
end
