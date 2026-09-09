defmodule EphCore.Ephemeris.Kernels.EOP do
  @moduledoc """
  Earth Orientation Parameters (EOP) path helpers.
  """

  alias EphCore.Ephemeris.Kernels

  def finals2000a_path, do: Kernels.time_path("finals2000A.all")

  def ensure_files do
    required = [finals2000a_path()]
    missing = Enum.reject(required, &File.exists?/1)

    if missing == [] do
      {:ok, :present}
    else
      {:error, {:missing, missing}}
    end
  end
end
