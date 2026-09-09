defmodule EphCoreTest do
  use ExUnit.Case, async: true

  test "observe/4 validates intent before ephemeris computation" do
    datetime = ~U[2026-02-02 12:00:00Z]
    location = %{lat: 44.9778, lon: -93.2650, height: 250}

    assert {:error, changeset} =
             EphCore.observe(datetime, location, [:sun], corrections: %{aberration: "yes"})

    assert {"aberration must be boolean", _} = Keyword.fetch!(changeset.errors, :corrections)
  end
end
