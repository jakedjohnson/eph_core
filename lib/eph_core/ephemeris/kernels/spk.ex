defmodule EphCore.Ephemeris.Kernels.SPK do
  @moduledoc """
  Public API for SPK kernel access.
  """

  alias EphCore.Ephemeris.Kernels.SPK.Server

  @spec position_at(integer(), integer(), float()) ::
          {:ok, {float(), float(), float()}} | {:error, term()}
  def position_at(target, center, seconds_past_j2000) do
    Server.position_at(target, center, seconds_past_j2000)
  end

  @doc """
  Telemetry-free variant of `position_at/3` for high-volume hot paths.
  """
  @spec position_at_fast(integer(), integer(), float()) ::
          {:ok, {float(), float(), float()}} | {:error, term()}
  def position_at_fast(target, center, seconds_past_j2000) do
    Server.position_at_fast(target, center, seconds_past_j2000)
  end

  @spec loaded?() :: boolean()
  def loaded?, do: Server.loaded?()

  @spec segments() :: [map()]
  def segments, do: Server.segments()
end
