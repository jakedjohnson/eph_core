defmodule Mix.Tasks.Eph.DownloadKernels do
  @moduledoc """
  Downloads the baseline ephemeris, time, and nutation data files.

  Fetches the DE440s planetary SPK kernel, the IERS Earth orientation file
  `finals2000A.all`, the NAIF leap-second kernel `naif0012.tls`, and the IAU
  2000A nutation tables (~32 MB total) into `ephemeris/` under
  `EphCore.Ephemeris.Kernels.base_dir/0` — `priv/` unless `:kernel_base_dir` is
  configured. Existing files are kept unless `--force` is given.

  Usage:
    mix eph.download_kernels
    mix eph.download_kernels --force

  For asteroid kernels, see `mix eph.generate_kernel`. For the optional
  Hipparcos fixed-star catalog, run `mix eph.setup_stars`.
  """

  use Mix.Task

  alias EphCore.Ephemeris.Kernels

  @shortdoc "Download baseline ephemeris, time, and nutation data files"

  @finals_urls [
    "https://datacenter.iers.org/data/9/finals2000A.all",
    "https://maia.usno.navy.mil/ser7/finals2000A.all",
    "http://maia.usno.navy.mil/ser7/finals2000A.all"
  ]

  @naif_urls [
    "https://naif.jpl.nasa.gov/pub/naif/generic_kernels/lsk/naif0012.tls"
  ]

  @nutation_a_urls [
    "https://iers-conventions.obspm.fr/content/chapter5/additional_info/tab5.3a.txt",
    "http://iers-conventions.obspm.fr/content/chapter5/additional_info/tab5.3a.txt"
  ]

  @nutation_b_urls [
    "https://iers-conventions.obspm.fr/content/chapter5/additional_info/tab5.3b.txt",
    "http://iers-conventions.obspm.fr/content/chapter5/additional_info/tab5.3b.txt"
  ]

  @spk_urls [
    "https://naif.jpl.nasa.gov/pub/naif/generic_kernels/spk/planets/de440s.bsp"
  ]

  @impl true
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: [force: :boolean])
    force = Keyword.get(opts, :force, false)

    ensure_http_clients()
    ensure_base_dir()

    files = [
      {Kernels.time_path("finals2000A.all"), @finals_urls},
      {Kernels.time_path("naif0012.tls"), @naif_urls},
      {Kernels.nutation_path("tab5.3a.txt"), @nutation_a_urls},
      {Kernels.nutation_path("tab5.3b.txt"), @nutation_b_urls},
      {Kernels.spk_path("de440s.bsp"), @spk_urls}
    ]

    Enum.each(files, fn {path, urls} ->
      download_file(path, urls, force)
    end)
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
      end
    end
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
