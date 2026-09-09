defmodule EphCore.Ephemeris.Kernels.SPK.Chebyshev do
  @moduledoc """
  Chebyshev polynomial evaluation using Clenshaw's recurrence.
  """

  @spec normalize_time(float(), float(), float()) :: float()
  def normalize_time(epoch, mid, radius) when is_number(radius) and radius != 0.0 do
    (epoch - mid) / radius
  end

  @doc """
  Evaluate a Chebyshev series whose coefficients are in the SPK-native
  **low-to-high** order (`[c0, c1, ...]`).
  """
  @spec evaluate([float()], float()) :: float()
  def evaluate(coefficients, t) when is_list(coefficients) and is_number(t) do
    coefficients |> Enum.reverse() |> clenshaw(t, 0.0, 0.0)
  end

  @doc """
  Evaluate a Chebyshev series whose coefficients are already in **high-to-low**
  order (`[cN, ..., c1, c0]`).

  This is the SPK hot path: the server pre-reverses each record's coefficients
  once at load time, so per-query evaluation skips the `Enum.reverse/1`.
  """
  @spec evaluate_reversed([float()], float()) :: float()
  def evaluate_reversed(reversed_coefficients, t)
      when is_list(reversed_coefficients) and is_number(t) do
    clenshaw(reversed_coefficients, t, 0.0, 0.0)
  end

  # Clenshaw recurrence over high-to-low coefficients. A direct recursive loop
  # avoids the per-term closure and {b1, b2} tuple allocation of Enum.reduce.
  defp clenshaw([c | rest], t, b1, b2) do
    clenshaw(rest, t, 2.0 * t * b1 - b2 + c, b1)
  end

  defp clenshaw([], t, b1, b2), do: b1 - t * b2
end
