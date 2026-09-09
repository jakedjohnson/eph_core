defmodule Mix.Tasks.Eph.GenerateKernel do
  @moduledoc """
  Generates an SPK kernel for a small body using the JPL Horizons API.

  Downloads a Type 21 (Extended Modified Difference Array) SPK file from
  Horizons and saves it to `priv/ephemeris/spk/asteroids/{naif_id}.bsp`.

  ## Usage

      mix eph.generate_kernel NAIF_ID [options]

  ## Arguments

    * `NAIF_ID` — NAIF/SPICE body ID (e.g. `2000001` for Ceres,
      `2000004` for Vesta). Must be an IAU numbered asteroid (2000001–2887103)
      or use the `--name` option for named lookup.

  ## Options

    * `--name NAME` — resolve by name instead of NAIF ID (e.g. `--name Ceres`)
    * `--start DATE` — coverage start (default: `1900-01-01`)
    * `--stop DATE` — coverage stop (default: `2200-01-01`)
    * `--out PATH` — output path (default: `priv/ephemeris/spk/asteroids/NAIF_ID.bsp`)
    * `--force` — overwrite existing file

  ## Examples

      mix eph.generate_kernel 2000001
      mix eph.generate_kernel 2000001 --start 1980-01-01 --stop 2050-01-01
      mix eph.generate_kernel 2000001 --name "Ceres" --force

  ## Notes

  The Horizons API endpoint used is:
  `https://ssd.jpl.nasa.gov/api/horizons_file.api`

  Requests must use `COMMAND='DES=NAIF_ID;'` for numbered asteroid lookup.
  The API returns a JSON response containing base64-encoded SPK binary data.
  """

  use Mix.Task

  alias EphCore.Ephemeris.Kernels

  @shortdoc "Generate SPK kernel for a small body via JPL Horizons API"
  @horizons_url "https://ssd.jpl.nasa.gov/api/horizons_file.api"

  @impl true
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        switches: [
          name: :string,
          start: :string,
          stop: :string,
          out: :string,
          force: :boolean
        ]
      )

    naif_id =
      case positional do
        [id | _] ->
          id

        [] ->
          Mix.shell().error("Usage: mix eph.generate_kernel NAIF_ID [options]")
          Mix.shell().error("  Example: mix eph.generate_kernel 2000001")
          exit(:shutdown)
      end

    start_time = Keyword.get(opts, :start, "1900-01-01")
    stop_time = Keyword.get(opts, :stop, "2200-01-01")
    force = Keyword.get(opts, :force, false)

    body_name = Keyword.get(opts, :name)

    default_out = Path.join(["asteroids", "#{naif_id}.bsp"])
    out_path = Kernels.spk_path(Keyword.get(opts, :out, default_out))

    if File.exists?(out_path) and not force do
      Mix.shell().info("skip #{out_path} (exists — use --force to overwrite)")
    else
      ensure_http_clients()
      ensure_base_dir(out_path)

      command =
        if body_name do
          "'#{body_name};'"
        else
          "'DES=#{naif_id};'"
        end

      Mix.shell().info(
        "Querying JPL Horizons for body #{command} (#{start_time} → #{stop_time})…"
      )

      case fetch_spk(command, start_time, stop_time) do
        {:ok, binary} ->
          File.write!(out_path, binary)
          size_kb = round(byte_size(binary) / 1024)
          Mix.shell().info("ok #{out_path} (#{size_kb} KB)")

        {:error, reason} ->
          Mix.shell().error("failed: #{inspect(reason)}")
          exit(:shutdown)
      end
    end
  end

  defp fetch_spk(command, start_time, stop_time) do
    # Horizons batch input file content.
    batch_input = """
    !$$SOF
    COMMAND=#{command}
    EPHEM_TYPE=SPK
    CENTER='500@0'
    START_TIME='#{start_time}'
    STOP_TIME='#{stop_time}'
    !$$EOF
    """

    params = %{
      "format" => "json",
      "input" => batch_input
    }

    case Req.post(@horizons_url, form: params, receive_timeout: 120_000) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        decode_response(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        error_msg = Map.get(body, "error", inspect(body))
        {:error, "HTTP #{status}: #{error_msg}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Response format: {"signature": ..., "spk_file_id": "...", "spk": "<base64>"}
  # The "spk" value is base64 with embedded newlines (MIME line wrapping).
  defp decode_response(%{"spk" => b64_with_newlines}) do
    # Strip newlines from MIME-wrapped base64.
    b64 = String.replace(b64_with_newlines, "\n", "")

    case Base.decode64(b64) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :base64_decode_failed}
    end
  end

  defp decode_response(%{"error" => msg}) do
    {:error, msg}
  end

  defp decode_response(other) do
    {:error, "unexpected response shape: #{inspect(other)}"}
  end

  defp ensure_http_clients do
    {:ok, _} = Application.ensure_all_started(:req)
  end

  defp ensure_base_dir(path) do
    case Application.get_env(:eph_core, :kernel_base_dir) do
      nil ->
        base_dir = Path.join(File.cwd!(), "priv")
        Application.put_env(:eph_core, :kernel_base_dir, base_dir)

      _ ->
        :ok
    end

    File.mkdir_p!(Path.dirname(path))
  end
end
