defmodule Mix.Tasks.Froth.Qwen.Clone do
  @shortdoc "Enroll Qwen cloned voice and generate realtime WAV preview"
  @moduledoc """
  Enroll a voice with DashScope/Qwen and synthesize a realtime preview WAV.

  Examples:

      mix froth.qwen.clone --file /tmp/sample.mp3 --name lex --register
      mix froth.qwen.clone --url https://song.less.rest/lex_sample.mp3 --name lex
      mix froth.qwen.clone --list
      mix froth.qwen.clone --delete qwen-voice-id
  """

  use Mix.Task

  alias Froth.Qwen.VoiceEnrollment
  alias Froth.VoiceClone

  @default_preview_text "Hey, this is a realtime voice clone test. How does this sound?"
  @default_target_model "qwen3-tts-vc-realtime-2026-01-15"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          file: :string,
          url: :string,
          name: :string,
          preferred_name: :string,
          preview: :string,
          enroll_text: :string,
          language: :string,
          out: :string,
          register: :boolean,
          target_model: :string,
          tts_model: :string,
          sample_rate: :integer,
          http_timeout_ms: :integer,
          preview_timeout_ms: :integer,
          page_size: :integer,
          page_index: :integer,
          list: :boolean,
          delete: :string
        ],
        aliases: [
          f: :file,
          u: :url,
          n: :name,
          p: :preview,
          o: :out,
          r: :register
        ]
      )

    if invalid != [] do
      Mix.raise("Unknown arguments: #{inspect(invalid)}")
    end

    if positional != [] do
      Mix.raise("Unexpected positional arguments: #{inspect(positional)}")
    end

    cond do
      opts[:list] ->
        list_voices(opts)

      is_binary(opts[:delete]) ->
        delete_voice(opts[:delete])

      true ->
        enroll_and_preview(opts)
    end
  end

  defp list_voices(opts) do
    ensure_req_started!()

    page_size = positive_integer_opt(opts, :page_size, 100)
    page_index = non_negative_integer_opt(opts, :page_index, 0)
    http_timeout_ms = positive_integer_opt(opts, :http_timeout_ms, 180_000)

    case VoiceEnrollment.list(
           page_size: page_size,
           page_index: page_index,
           http_timeout_ms: http_timeout_ms
         ) do
      {:ok, []} ->
        Mix.shell().info("No enrolled voices found.")

      {:ok, voices} ->
        Enum.each(voices, fn voice ->
          id = voice["voice"] || "?"
          target_model = voice["target_model"] || "?"
          language = voice["language"] || "?"
          created_at = voice["gmt_create"] || "?"

          Mix.shell().info(
            "#{id}\ttarget_model=#{target_model}\tlanguage=#{language}\tcreated=#{created_at}"
          )
        end)

      {:error, reason} ->
        Mix.raise("Failed to list voices: #{inspect(reason)}")
    end
  end

  defp delete_voice(voice_id) do
    ensure_req_started!()

    case VoiceEnrollment.delete(voice_id, http_timeout_ms: 180_000) do
      :ok ->
        Mix.shell().info("Deleted voice: #{voice_id}")

      {:error, reason} ->
        Mix.raise("Failed to delete voice #{voice_id}: #{inspect(reason)}")
    end
  end

  defp enroll_and_preview(opts) do
    ensure_realtime_started!()

    source = source_from_opts!(opts)
    name = opts[:name] || default_name(source)

    preferred_name =
      opts
      |> Keyword.get(:preferred_name, slug(name))
      |> normalize_preferred_name()

    preview_text = opts[:preview] || @default_preview_text
    target_model = opts[:target_model] || @default_target_model
    tts_model = opts[:tts_model] || target_model
    sample_rate = positive_integer_opt(opts, :sample_rate, 24_000)
    http_timeout_ms = positive_integer_opt(opts, :http_timeout_ms, 180_000)
    preview_timeout_ms = positive_integer_opt(opts, :preview_timeout_ms, 45_000)
    output_path = opts[:out] || default_output_path(preferred_name)

    create_opts =
      [
        preferred_name: preferred_name,
        target_model: target_model,
        language: opts[:language],
        enrollment_text: opts[:enroll_text],
        http_timeout_ms: http_timeout_ms
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    Mix.shell().info("Enrolling voice from #{source_label(source)}...")

    enrollment_result =
      case source do
        {:file, path} -> VoiceEnrollment.create_from_file(path, create_opts)
        {:url, url} -> VoiceEnrollment.create_from_url(url, create_opts)
      end

    case enrollment_result do
      {:ok, %{voice: voice}} ->
        Mix.shell().info("Enrolled voice id: #{voice}")

        case VoiceEnrollment.preview_to_wav(
               voice,
               preview_text,
               output_path,
               tts_model: tts_model,
               sample_rate: sample_rate,
               preview_timeout_ms: preview_timeout_ms
             ) do
          {:ok, preview} ->
            Mix.shell().info(
              "Preview written: #{preview.path} (#{preview.bytes} bytes @ #{preview.sample_rate}Hz)"
            )

            if opts[:register] do
              ensure_repo_started!()
              register_voice!(voice, name, source, tts_model, opts[:language])
            end

          {:error, reason} ->
            Mix.raise("Enrollment succeeded but preview synthesis failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("Voice enrollment failed: #{inspect(reason)}")
    end
  end

  defp register_voice!(voice_id, name, source, tts_model, language) do
    date = Date.utc_today() |> Date.to_iso8601()

    register_opts = [
      source_url: source_for_db(source),
      clone_model: "qwen-voice-enrollment",
      tts_model: tts_model,
      language: language || "Auto",
      created_by: "mix:froth.qwen.clone",
      notes: "Qwen voice enrollment (#{date})"
    ]

    case VoiceClone.register(voice_id, name, register_opts) do
      {:ok, _row} ->
        Mix.shell().info("Registered in voice_clones: #{name} -> #{voice_id}")

      {:error, changeset} ->
        Mix.raise("Failed to register voice clone: #{format_changeset_errors(changeset)}")
    end
  end

  defp source_from_opts!(opts) do
    file = opts[:file]
    url = opts[:url]

    cond do
      is_binary(file) and is_binary(url) ->
        Mix.raise("Use either --file or --url, not both.")

      is_binary(file) ->
        unless File.exists?(file), do: Mix.raise("File not found: #{file}")
        {:file, file}

      is_binary(url) ->
        {:url, url}

      true ->
        Mix.raise("Provide --file /path/to/audio or --url https://example/audio.mp3")
    end
  end

  defp source_label({:file, path}), do: path
  defp source_label({:url, url}), do: url

  defp source_for_db({:file, path}), do: path
  defp source_for_db({:url, url}), do: url

  defp default_name({:file, path}) do
    path
    |> Path.basename()
    |> Path.rootname()
    |> String.replace("_", " ")
    |> String.replace("-", " ")
    |> String.trim()
    |> case do
      "" -> "Qwen Voice Clone"
      value -> value
    end
  end

  defp default_name({:url, url}) do
    uri = URI.parse(url)

    uri.path
    |> to_string()
    |> Path.basename()
    |> Path.rootname()
    |> String.replace("_", " ")
    |> String.replace("-", " ")
    |> String.trim()
    |> case do
      "" -> "Qwen Voice Clone"
      value -> value
    end
  end

  defp default_output_path(preferred_name) do
    Path.join("tmp", "#{preferred_name}_qwen_preview.wav")
  end

  defp slug(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 16)
    |> case do
      "" -> "voice_#{System.system_time(:second)}"
      value -> value
    end
  end

  defp normalize_preferred_name(name) do
    name
    |> to_string()
    |> String.replace(~r/[^0-9A-Za-z_]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 16)
    |> case do
      "" -> "voice_#{System.system_time(:second)}"
      value -> value
    end
  end

  defp positive_integer_opt(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 do
      value
    else
      Mix.raise("--#{key} must be a positive integer")
    end
  end

  defp non_negative_integer_opt(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value >= 0 do
      value
    else
      Mix.raise("--#{key} must be a non-negative integer")
    end
  end

  defp format_changeset_errors(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} ->
        msg
      end)

    inspect(errors)
  end

  defp ensure_req_started! do
    case Application.ensure_all_started(:req) do
      {:ok, _apps} -> :ok
      {:error, reason} -> Mix.raise("Failed to start Req dependencies: #{inspect(reason)}")
    end
  end

  defp ensure_realtime_started! do
    ensure_req_started!()

    case Application.ensure_all_started(:fresh) do
      {:ok, _apps} -> :ok
      {:error, reason} -> Mix.raise("Failed to start websocket dependencies: #{inspect(reason)}")
    end

    case Application.ensure_all_started(:phoenix_pubsub) do
      {:ok, _apps} -> :ok
      {:error, reason} -> Mix.raise("Failed to start PubSub dependencies: #{inspect(reason)}")
    end

    ensure_pubsub_started!()
  end

  defp ensure_pubsub_started! do
    if Process.whereis(Froth.PubSub) do
      :ok
    else
      case Supervisor.start_link([{Phoenix.PubSub, name: Froth.PubSub}], strategy: :one_for_one) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          Mix.raise("Failed to start Froth.PubSub: #{inspect(reason)}")
      end
    end
  end

  defp ensure_repo_started! do
    case Application.ensure_all_started(:ecto_sql) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        Mix.raise("Failed to start Ecto dependencies: #{inspect(reason)}")
    end

    case Froth.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> Mix.raise("Failed to start Froth.Repo: #{inspect(reason)}")
    end
  end
end
