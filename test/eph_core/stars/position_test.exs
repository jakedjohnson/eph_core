defmodule EphCore.Stars.PositionTest do
  use ExUnit.Case, async: false

  alias EphCore.Stars.{Catalog, Position}

  @jake_birth_jd_tt 2_448_554.555556

  describe "compute/3" do
    test "Regulus ecliptic longitude at Jake's birth epoch is approximately 149.8°" do
      {:ok, regulus} = Catalog.lookup(49_669)

      assert regulus.name == "Regulus"

      position = Position.compute(regulus, @jake_birth_jd_tt)

      IO.puts("""
      Regulus at JD #{@jake_birth_jd_tt}:
        ecliptic_lon_deg: #{position.ecliptic_lon_deg}
        ecliptic_lat_deg: #{position.ecliptic_lat_deg}
        ra_deg: #{position.ra_deg}
        dec_deg: #{position.dec_deg}
        magnitude: #{position.magnitude}
      """)

      assert_in_delta position.ecliptic_lon_deg, 149.8, 0.5
    end

    test "Sirius ecliptic latitude is approximately -40°" do
      {:ok, sirius} = Catalog.lookup(32_349)

      assert sirius.name == "Sirius"

      position = Position.compute(sirius, @jake_birth_jd_tt)

      assert_in_delta position.ecliptic_lat_deg, -40.0, 1.0
    end
  end

  describe "Catalog" do
    test "significance_list/0 returns nine configured stars" do
      assert map_size(Catalog.significance_list()) == 9
    end

    test "all_significant/0 returns records for every configured star" do
      stars = Catalog.all_significant()

      assert length(stars) == 9
      assert Enum.all?(stars, &is_map/1)
      assert Enum.all?(stars, &(&1.name != nil))
    end

    test "all/0 returns many valid stars and skips incomplete RA/Dec rows" do
      stars = Catalog.all()

      # Full Hipparcos is ~118k rows; ~263 have blank RA/Dec.
      assert length(stars) > 100_000
      assert length(stars) < 118_218
      refute Enum.any?(stars, &(&1.hip == 55_203))
    end
  end

  describe "compute_many/3" do
    test "matches compute/3 for significant stars at a shared epoch" do
      stars = Catalog.all_significant()
      singles = Enum.map(stars, &Position.compute(&1, @jake_birth_jd_tt))
      batched = Position.compute_many(stars, @jake_birth_jd_tt)

      assert length(batched) == length(singles)

      Enum.zip(singles, batched)
      |> Enum.each(fn {a, b} ->
        assert a.hip == b.hip
        assert_in_delta a.ra_deg, b.ra_deg, 1.0e-9
        assert_in_delta a.dec_deg, b.dec_deg, 1.0e-9
        assert_in_delta a.ecliptic_lon_deg, b.ecliptic_lon_deg, 1.0e-9
      end)
    end
  end
end
