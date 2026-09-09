defmodule Mix.Tasks.Eph.SetupStars do
  @moduledoc """
  Sets up the optional Hipparcos star catalog for fixed-star features.

  Usage:
    mix eph.setup_stars
    mix eph.setup_stars --force

  Downloads `hip_main.dat` (VizieR catalog I/239 / ESA Hipparcos) into
  `priv/stars/` by default. Fixed-star APIs are optional until this file exists.

  Manual setup: download `hip_main.dat` from the
  [VizieR I/239 catalog page](https://cdsarc.cds.unistra.fr/viz-bin/Cat/I/239)
  and place it at the path printed by this task.
  """

  use Mix.Task

  alias EphCore.Ephemeris.Kernels

  @shortdoc "Download optional Hipparcos star catalog (hip_main.dat)"

  @hip_main_urls [
    "https://cdsarc.cds.unistra.fr/ftp/cats/I/239/hip_main.dat"
  ]

  @impl true
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: [force: :boolean])
    force = Keyword.get(opts, :force, false)

    ensure_http_clients()
    ensure_base_dir()

    path = Kernels.stars_path("hip_main.dat")
    download_file(path, @hip_main_urls, force)
  end

  defp ensure_http_clients do
    {:ok, _} = Application.ensure_all_started(:req)
  end

  defp ensure_base_dir do
    case Application.get_env(:eph_core, :kernel_base_dir) do
      nil ->
        base_dir = Path.join(File.cwd!(), "priv")
        Application.put_env(:eph_core, :kernel_base_dir, base_dir)

      _ ->
        :ok
    end
  end

  defp download_file(path, urls, force) do
    if File.exists?(path) and not force do
      Mix.shell().info("skip #{path} (exists, use --force to overwrite)")
    else
      File.mkdir_p!(Path.dirname(path))

      case fetch_first(urls) do
        {:ok, body, url} ->
          File.write!(path, body)
          Mix.shell().info("ok #{path} (#{url})")

        {:error, reason} ->
          Mix.shell().error("failed #{path}: #{inspect(reason)}")
          print_manual_setup(path)
      end
    end
  end

  defp print_manual_setup(path) do
    Mix.shell().error("""
    Manual setup:
      1. Open https://cdsarc.cds.unistra.fr/viz-bin/Cat/I/239
      2. Download hip_main.dat (~51 MB)
      3. Place it at #{path}
    """)
  end

  defp fetch_first([]), do: {:error, :no_urls}

  defp fetch_first([url | rest]) do
    case http_get(url) do
      {:ok, body} -> {:ok, body, url}
      {:error, reason} -> fetch_first(rest, reason)
    end
  end

  defp fetch_first([], last_error), do: {:error, last_error || :no_urls}

  defp fetch_first([url | rest], _last_error) do
    case http_get(url) do
      {:ok, body} -> {:ok, body, url}
      {:error, reason} -> fetch_first(rest, reason)
    end
  end

  defp http_get(url) do
    case Req.get(url) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
