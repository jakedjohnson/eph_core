defmodule EphCore.Ephemeris.Kernels.LSK do
  @moduledoc """
  Leap-seconds kernel (LSK) path helpers.
  """

  alias EphCore.Ephemeris.Kernels

  def naif_path, do: Kernels.time_path("naif0012.tls")
  def skyfield_path, do: Kernels.time_path("tai-utc.dat")

  def ensure_files do
    required = [naif_path()]
    missing = Enum.reject(required, &File.exists?/1)

    if missing == [] do
      {:ok, :present}
    else
      {:error, {:missing, missing}}
    end
  end
end
