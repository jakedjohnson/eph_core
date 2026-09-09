defmodule EphCore.Ephemeris.Kernels.SPK.Segment do
  @moduledoc """
  SPK segment descriptor helpers.
  """

  defstruct [
    :target,
    :center,
    :frame,
    :data_type,
    :start_epoch,
    :end_epoch,
    :start_addr,
    :end_addr
  ]

  @type t :: %__MODULE__{
          target: integer(),
          center: integer(),
          frame: integer(),
          data_type: integer(),
          start_epoch: float(),
          end_epoch: float(),
          start_addr: integer(),
          end_addr: integer()
        }

  @spec from_summary(%{double: [float()], int: [integer()]}) :: t()
  def from_summary(%{double: [start_epoch, end_epoch], int: ints}) do
    [target, center, frame, data_type, start_addr, end_addr] = ints

    %__MODULE__{
      target: target,
      center: center,
      frame: frame,
      data_type: data_type,
      start_epoch: start_epoch,
      end_epoch: end_epoch,
      start_addr: start_addr,
      end_addr: end_addr
    }
  end

  @spec covers?(t(), float()) :: boolean()
  def covers?(%__MODULE__{start_epoch: start_epoch, end_epoch: end_epoch}, epoch_seconds) do
    epoch_seconds >= start_epoch and epoch_seconds <= end_epoch
  end

  @spec find_for([t()], integer(), integer(), float()) :: t() | nil
  def find_for(segments, target, center, epoch) do
    Enum.find(segments, fn segment ->
      segment.target == target and segment.center == center and covers?(segment, epoch)
    end)
  end
end
