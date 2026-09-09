defmodule EphCore.Ephemeris.Kernels do
  @moduledoc """
  Resolves on-disk paths for the ephemeris, time, nutation, and star data files.

  No data is bundled with the package. Everything is resolved under
  `base_dir/0`: `:kernel_base_dir` when set, otherwise `$PWD/priv` if baseline
  files are there, else the compiled `:eph_core` priv directory.

      config :eph_core, kernel_base_dir: "/var/eph_core/data"

  Releases and other non-project working directories must set `:kernel_base_dir`.
  See the README for how to download or generate each file.
  """

  @baseline_files [
    {:time, "naif0012.tls"},
    {:time, "finals2000A.all"},
    {:nutation, "tab5.3a.txt"},
    {:nutation, "tab5.3b.txt"},
    {:spk, "de440s.bsp"}
  ]

  @doc """
  Returns the base directory for kernel files.

  Uses the configured `:kernel_base_dir` from application env. When unset,
  prefers `$PWD/priv` if baseline files exist there (Hex/Mix consumer after
  `mix eph.download_kernels`), otherwise `:code.priv_dir(:eph_core)` (path-dep
  and Livebook installs that copy project `priv/`).

  Note: This must be a runtime function call, not a module attribute, because
  kernel_base_dir is configured at runtime in releases via runtime.exs.
  """
  def base_dir do
    case Application.get_env(:eph_core, :kernel_base_dir) do
      nil -> inferred_priv_dir()
      dir -> dir
    end
  end

  defp inferred_priv_dir do
    cwd_priv = Path.join(File.cwd!(), "priv")
    code_priv = compiled_priv_dir()

    cond do
      baseline_present?(cwd_priv) -> cwd_priv
      is_binary(code_priv) and baseline_present?(code_priv) -> code_priv
      true -> cwd_priv
    end
  end

  defp compiled_priv_dir do
    case :code.priv_dir(:eph_core) do
      {:error, :bad_name} -> nil
      path when is_list(path) -> List.to_string(path)
    end
  end

  defp baseline_present?(base) do
    File.exists?(Path.join([base, "ephemeris", "spk", "de440s.bsp"]))
  end

  @doc """
  Raises if the baseline kernel files required to boot EphCore are missing.

  Hipparcos stars and asteroid SPKs are optional and are not checked here.
  """
  def require_baseline! do
    missing =
      @baseline_files
      |> Enum.map(fn {kind, name} -> baseline_path(kind, name) end)
      |> Enum.reject(&File.exists?/1)

    if missing != [] do
      raise """
      EphCore cannot start; baseline data files are missing:

      #{Enum.map_join(missing, "\n", &"  #{&1}")}

      From the Mix project root:

          mix eph.download_kernels

      Files are read from `:kernel_base_dir` when set. Otherwise EphCore looks
      in `./priv`, then in the compiled `:eph_core` priv directory. Set
      `:kernel_base_dir` in releases, or whenever the process working directory
      is not the app root.
      """
    end

    :ok
  end

  defp baseline_path(:time, name), do: time_path(name)
  defp baseline_path(:nutation, name), do: nutation_path(name)
  defp baseline_path(:spk, name), do: spk_path(name)

  def time_path(filename) when is_binary(filename) do
    Path.join([base_dir(), "ephemeris", "time", filename])
  end

  def kernel_path(filename) when is_binary(filename) do
    Path.join([base_dir(), "ephemeris", "kernels", filename])
  end

  def spk_path(filename) when is_binary(filename) do
    Path.join([base_dir(), "ephemeris", "spk", filename])
  end

  def nutation_path(filename) when is_binary(filename) do
    Path.join([base_dir(), "ephemeris", "nutation", filename])
  end

  def stars_path(filename) when is_binary(filename) do
    Path.join([base_dir(), "stars", filename])
  end
end
