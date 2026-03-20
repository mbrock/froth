defmodule Froth.Browser.Chrome do
  @moduledoc false

  @type profile :: :headless_bulk | :headless_gpu | :headful_debug | :headful_benchmark

  @default_candidates [
    "chromium",
    "chromium-browser",
    "google-chrome",
    "google-chrome-stable",
    "chrome"
  ]

  @common_flags [
    "--disable-dev-shm-usage",
    "--no-first-run",
    "--no-default-browser-check",
    "--remote-debugging-port=0",
    "--hide-scrollbars"
  ]

  def find_executable(opts \\ []) when is_list(opts) do
    explicit = Keyword.get(opts, :explicit)
    candidates = Keyword.get(opts, :candidates, @default_candidates)
    resolver = Keyword.get(opts, :resolver, &System.find_executable/1)

    cond do
      is_binary(explicit) and explicit != "" ->
        case if(File.exists?(explicit), do: explicit, else: resolver.(explicit)) do
          nil -> {:error, {:browser_executable_not_found, explicit}}
          path -> {:ok, path}
        end

      true ->
        case Enum.find_value(candidates, fn candidate -> resolver.(candidate) end) do
          nil -> {:error, :browser_executable_not_found}
          path -> {:ok, path}
        end
    end
  end

  def launch_args(user_data_dir, opts \\ []) when is_binary(user_data_dir) and is_list(opts) do
    profile = normalize_profile(Keyword.get(opts, :profile))
    extra_args = Keyword.get(opts, :extra_args, [])

    [
      "--user-data-dir=#{user_data_dir}"
      | profile_flags(profile)
        |> Kernel.++(@common_flags)
    ] ++ extra_args ++ ["about:blank"]
  end

  def default_profile, do: :headless_bulk

  def normalize_profile(profile)
      when profile in [:headless_bulk, :headless_gpu, :headful_debug, :headful_benchmark],
      do: profile

  def normalize_profile(profile) when is_binary(profile) do
    case String.trim(profile) |> String.downcase() do
      "headless_gpu" -> :headless_gpu
      "headful_debug" -> :headful_debug
      "headful_benchmark" -> :headful_benchmark
      "headless_bulk" -> :headless_bulk
      _ -> default_profile()
    end
  end

  def normalize_profile(_profile), do: default_profile()

  def profile_metadata(profile) do
    profile = normalize_profile(profile)

    %{
      profile: profile,
      headless?: profile in [:headless_bulk, :headless_gpu],
      headful?: profile in [:headful_debug, :headful_benchmark],
      visible?: profile in [:headful_debug, :headful_benchmark],
      gpu?: profile in [:headless_gpu, :headful_debug, :headful_benchmark],
      audio_muted?: profile in [:headless_bulk, :headless_gpu, :headful_benchmark],
      webcodecs?: true,
      codecs: ["h264"],
      browser_family: "chromium"
    }
  end

  def parse_devtools_active_port(contents) when is_binary(contents) do
    case String.split(contents, ~r/\R/, trim: true) do
      [port, browser_path | _rest] ->
        case Integer.parse(port) do
          {port_number, ""} -> {:ok, %{port: port_number, browser_path: browser_path}}
          _ -> {:error, :invalid_devtools_port}
        end

      _ ->
        {:error, :invalid_devtools_port}
    end
  end

  defp profile_flags(:headless_bulk) do
    ["--headless=new", "--disable-gpu", "--mute-audio"]
  end

  defp profile_flags(:headless_gpu) do
    ["--headless=new", "--mute-audio"]
  end

  defp profile_flags(:headful_debug) do
    ["--start-maximized"]
  end

  defp profile_flags(:headful_benchmark) do
    ["--start-maximized", "--mute-audio"]
  end
end
