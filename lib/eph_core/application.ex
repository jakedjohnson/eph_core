defmodule EphCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    EphCore.Ephemeris.Kernels.require_baseline!()

    children = [
      EphCore.AstronomicalTime.Tables.LeapSeconds,
      EphCore.AstronomicalTime.Tables.EarthOrientationParameters,
      EphCore.EarthOrientation.Tables.NutationIAU2000A,
      EphCore.Ephemeris.Kernels.SPK.Server
    ]

    opts = [strategy: :one_for_one, name: EphCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
