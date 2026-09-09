defmodule EphCore.Ephemeris.KernelsTest do
  use ExUnit.Case, async: false

  alias EphCore.Ephemeris.Kernels

  setup do
    original = Application.get_env(:eph_core, :kernel_base_dir)
    on_exit(fn -> Application.put_env(:eph_core, :kernel_base_dir, original) end)
    :ok
  end

  describe "base_dir/0" do
    test "defaults to ./priv when kernel_base_dir is unset" do
      Application.delete_env(:eph_core, :kernel_base_dir)

      assert Kernels.base_dir() == Path.join(File.cwd!(), "priv")
    end
  end

  describe "require_baseline!/0" do
    test "raises with download instructions when baseline files are missing" do
      base = Path.join(System.tmp_dir!(), "eph_core_missing_#{System.unique_integer()}")
      Application.put_env(:eph_core, :kernel_base_dir, base)

      error = assert_raise RuntimeError, fn -> Kernels.require_baseline!() end
      assert error.message =~ "mix eph.download_kernels"
      assert error.message =~ "naif0012.tls"
    end

    test "returns :ok when baseline files are present" do
      Application.put_env(:eph_core, :kernel_base_dir, Path.join(File.cwd!(), "priv"))

      assert Kernels.require_baseline!() == :ok
    end
  end

  describe "stars_path/1" do
    test "joins filename under stars/ relative to default priv base" do
      base = Path.join(File.cwd!(), "priv")
      Application.put_env(:eph_core, :kernel_base_dir, base)

      assert Kernels.stars_path("hip_main.dat") ==
               Path.join([base, "stars", "hip_main.dat"])
    end

    test "follows configured kernel_base_dir" do
      base = Path.join(System.tmp_dir!(), "eph_core_kernels_test_#{System.unique_integer()}")
      Application.put_env(:eph_core, :kernel_base_dir, base)

      assert Kernels.stars_path("hip_main.dat") ==
               Path.join([base, "stars", "hip_main.dat"])
    end
  end
end
