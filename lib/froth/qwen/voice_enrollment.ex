defmodule Froth.Qwen.VoiceEnrollment do
  @moduledoc """
  DashScope voice enrollment helpers for Qwen realtime voice-clone TTS.

  This module supports:
  - creating an enrolled voice from a local file or public URL
  - listing and deleting enrolled voices
  - generating a realtime TTS preview and writing it as a WAV file
  """

  alias Froth.Qwen

  @base_url "https://dashscope-intl.aliyuncs.com"
  @customization_path "/api/v1/services/audio/tts/customization"
  @enrollment_model "qwen-voice-enrollment"
  @default_target_model "qwen3-tts-vc-realtime-2026-01-15"
  @default_sample_rate 24_000
  @default_http_timeout_ms 180_000
  @default_preview_timeout_ms 45_000

  @doc """
  Create an enrolled voice from a local audio file.
  """
  def create_from_file(path, opts \\ []) when is_binary(path) do
    with {:ok, audio} <- File.read(path) do
      mime = Keyword.get(opts, :mime_type, infer_mime_type(path))
      create_from_data_uri("data:#{mime};base64,#{Base.encode64(audio)}", opts)
    else
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  @doc """
  Create an enrolled voice from a public audio URL.
  """
  def create_from_url(url, opts \\ []) when is_binary(url) do
    create_from_data_uri(url, opts)
  end

  @doc """
  List enrolled voices.
  """
  def list(opts \\ []) do
    input = %{
      action: "list",
      page_index: Keyword.get(opts, :page_index, 0),
      page_size: Keyword.get(opts, :page_size, 100)
    }

    with {:ok, body} <- post_customization(input, opts) do
      {:ok, get_in(body, ["output", "voice_list"]) || []}
    end
  end

  @doc """
  Delete an enrolled voice by voice id.
  """
  def delete(voice, opts \\ []) when is_binary(voice) do
    input = %{action: "delete", voice: voice}

    case post_customization(input, opts) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Generate a realtime TTS preview and write a WAV file to `output_path`.
  """
  def preview_to_wav(voice, text, output_path, opts \\ [])
      when is_binary(voice) and is_binary(text) and is_binary(output_path) do
    with {:ok, pcm, sample_rate} <- synthesize_pcm(voice, text, opts),
         :ok <- write_wav(output_path, pcm, sample_rate) do
      {:ok, %{path: output_path, sample_rate: sample_rate, bytes: byte_size(pcm)}}
    end
  end

  @doc """
  Generate a realtime TTS preview and return raw PCM.
  """
  def synthesize_pcm(voice, text, opts \\ []) when is_binary(voice) and is_binary(text) do
    sample_rate = Keyword.get(opts, :sample_rate, @default_sample_rate)

    tts_model =
      Keyword.get(opts, :tts_model, Keyword.get(opts, :target_model, @default_target_model))

    timeout_ms = Keyword.get(opts, :preview_timeout_ms, @default_preview_timeout_ms)
    topic = "qwen:voice_preview:#{System.unique_integer([:positive, :monotonic])}"

    session = %{
      mode: "server_commit",
      voice: voice,
      response_format: "pcm",
      sample_rate: sample_rate,
      language_type: Keyword.get(opts, :language_type, "Auto")
    }

    :ok = Phoenix.PubSub.subscribe(Froth.PubSub, topic)

    result =
      case Qwen.start_link(
             topic: topic,
             model: tts_model,
             session: session,
             api_key: api_key(opts)
           ) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          Qwen.send_event(pid, %{type: "input_text_buffer.append", text: text})
          Qwen.send_event(pid, %{type: "input_text_buffer.commit"})
          Qwen.send_event(pid, %{type: "session.finish"})
          await_tts_audio(pid, ref, timeout_ms, [])

        {:error, reason} ->
          {:error, {:tts_start_failed, reason}}
      end

    Phoenix.PubSub.unsubscribe(Froth.PubSub, topic)

    case result do
      {:ok, pcm} -> {:ok, pcm, sample_rate}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Write 16-bit mono PCM to a WAV file.
  """
  def write_wav(path, pcm, sample_rate)
      when is_binary(path) and is_binary(pcm) and is_integer(sample_rate) and sample_rate > 0 do
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, [wav_header(byte_size(pcm), sample_rate), pcm]) do
      :ok
    end
  end

  defp create_from_data_uri(audio_data, opts) do
    preferred_name =
      opts
      |> Keyword.get(:preferred_name, default_voice_name())
      |> normalize_preferred_name()

    target_model = Keyword.get(opts, :target_model, @default_target_model)

    input =
      %{
        action: "create",
        target_model: target_model,
        preferred_name: preferred_name,
        audio: %{data: audio_data}
      }
      |> maybe_put("language", Keyword.get(opts, :language))
      |> maybe_put("text", Keyword.get(opts, :enrollment_text))

    with {:ok, body} <- post_customization(input, opts),
         {:ok, voice} <- extract_voice(body) do
      {:ok,
       %{
         voice: voice,
         preferred_name: preferred_name,
         target_model: target_model,
         response: body
       }}
    end
  end

  defp post_customization(input, opts) when is_map(input) do
    with {:ok, key} <- fetch_api_key(opts),
         {:ok, response} <-
           Req.post(
             base_url: Keyword.get(opts, :base_url, @base_url),
             url: @customization_path,
             receive_timeout: Keyword.get(opts, :http_timeout_ms, @default_http_timeout_ms),
             retry: false,
             headers: [{"authorization", "Bearer #{key}"}],
             json: %{model: @enrollment_model, input: input}
           ) do
      normalize_http_response(response)
    end
  end

  defp normalize_http_response(%Req.Response{status: status, body: body})
       when status in 200..299 do
    if is_map(body) do
      case Map.get(body, "code") do
        nil -> {:ok, body}
        200 -> {:ok, body}
        "200" -> {:ok, body}
        code -> {:error, {:api_error, code, Map.get(body, "message"), body}}
      end
    else
      {:error, {:invalid_response_body, body}}
    end
  end

  defp normalize_http_response(%Req.Response{status: status, body: body}) do
    {:error, {:http_error, status, body}}
  end

  defp normalize_http_response({:error, reason}), do: {:error, {:request_failed, reason}}

  defp extract_voice(body) when is_map(body) do
    case get_in(body, ["output", "voice"]) do
      voice when is_binary(voice) and voice != "" -> {:ok, voice}
      _ -> {:error, {:unexpected_create_response, body}}
    end
  end

  defp await_tts_audio(pid, ref, timeout_ms, chunks) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_tts_audio(pid, ref, deadline, chunks)
  end

  defp do_await_tts_audio(pid, ref, deadline, chunks) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:tts_audio, pcm} when is_binary(pcm) ->
        do_await_tts_audio(pid, ref, deadline, [pcm | chunks])

      :tts_response_done ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      :qwen_ws_finished ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:qwen_ws_error, reason} ->
        {:error, {:qwen_ws_error, reason}}

      {:DOWN, ^ref, :process, _down_pid, reason} ->
        cond do
          reason in [:normal, :shutdown] and chunks != [] ->
            {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

          reason in [:normal, :shutdown] ->
            {:error, :no_audio_returned}

          true ->
            {:error, {:tts_process_down, reason}}
        end
    after
      timeout ->
        if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :normal)
        {:error, :preview_timeout}
    end
  end

  defp fetch_api_key(opts) do
    case api_key(opts) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_alibaba_api_key}
    end
  end

  defp api_key(opts) do
    Keyword.get(opts, :api_key) ||
      System.get_env("ALIBABA_API_KEY") ||
      System.get_env("DASHSCOPE_API_KEY")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp infer_mime_type(path) do
    case String.downcase(Path.extname(path)) do
      ".wav" -> "audio/wav"
      ".mp3" -> "audio/mpeg"
      ".m4a" -> "audio/mp4"
      ".ogg" -> "audio/ogg"
      ".flac" -> "audio/flac"
      _ -> "audio/mpeg"
    end
  end

  defp default_voice_name do
    "voice_#{System.system_time(:second)}"
  end

  defp normalize_preferred_name(name) do
    normalized =
      name
      |> to_string()
      |> String.replace(~r/[^0-9A-Za-z_]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 16)

    if normalized == "", do: default_voice_name(), else: normalized
  end

  defp wav_header(pcm_bytes, sample_rate) do
    channels = 1
    bits_per_sample = 16
    byte_rate = sample_rate * channels * div(bits_per_sample, 8)
    block_align = channels * div(bits_per_sample, 8)
    chunk_size = 36 + pcm_bytes

    <<
      "RIFF",
      chunk_size::little-32,
      "WAVE",
      "fmt ",
      16::little-32,
      1::little-16,
      channels::little-16,
      sample_rate::little-32,
      byte_rate::little-32,
      block_align::little-16,
      bits_per_sample::little-16,
      "data",
      pcm_bytes::little-32
    >>
  end
end
