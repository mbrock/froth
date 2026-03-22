defmodule Froth.Video do
  @moduledoc """
  Browser-rendered video composition and deterministic frame capture.

  The core API centers on:

  - `compose/4` for building a self-contained HTML episode
  - `record/2` for deterministic frame-by-frame rendering
  - `record_task/2` and `from_podcast/2` for long-running background jobs
  """

  alias Froth.Podcast.Script
  alias Froth.Repo
  alias Froth.Tasks.Video, as: VideoTask
  alias Froth.Video.{ComputeRenderer, EpisodeTemplate, RenderSupport}

  @default_scene_concurrency 4
  @default_scene_model "black-forest-labs/flux-2-pro"
  @default_transcription_model "victor-upmeet/whisperx"
  @default_transcription_language "en"
  @default_bot_id "charlie"

  def compose(words, scenes, audio_url \\ nil, opts \\ [])
      when is_list(words) and is_list(scenes) and (is_binary(audio_url) or is_nil(audio_url)) and
             is_list(opts) do
    EpisodeTemplate.render(words, scenes, audio_url, opts)
  end

  def record_task(html, opts \\ []) when is_binary(html) and is_list(opts) do
    opts = maybe_put_telegram_opts(opts)
    VideoTask.run_record(html, opts)
  end

  def from_podcast(batch_id, opts \\ []) when is_binary(batch_id) and is_list(opts) do
    opts = maybe_put_telegram_opts(opts)
    VideoTask.run_podcast(batch_id, opts)
  end

  def record_compute(html, opts \\ []) when is_binary(html) and is_list(opts) do
    ComputeRenderer.record(html, opts)
  end

  @doc false
  def render_podcast(batch_id, opts \\ []) when is_binary(batch_id) and is_list(opts) do
    with {:ok, prepared} <- prepare_podcast_render(batch_id, opts) do
      record_fun = Keyword.get(opts, :record_fun, &record/2)

      try do
        with {:ok, output_path} <- record_fun.(prepared.html, prepared.record_opts),
             :ok <- maybe_send_video(prepared.script, output_path, opts) do
          {:ok, podcast_result(prepared, batch_id, output_path)}
        end
      after
        if prepared.cleanup_audio? do
          File.rm(prepared.audio_path)
        end
      end
    end
  end

  @doc false
  def render_podcast_compute(batch_id, opts \\ [])
      when is_binary(batch_id) and is_list(opts) do
    with {:ok, prepared} <- prepare_podcast_render(batch_id, opts) do
      record_fun = Keyword.get(opts, :record_compute_fun, &record_compute/2)

      try do
        with {:ok, output_path} <- record_fun.(prepared.html, prepared.record_opts),
             :ok <- maybe_send_video(prepared.script, output_path, opts) do
          {:ok, podcast_result(prepared, batch_id, output_path)}
        end
      after
        if prepared.cleanup_audio? do
          File.rm(prepared.audio_path)
        end
      end
    end
  end

  def transcribe(audio_url, opts \\ []) when is_binary(audio_url) and is_list(opts) do
    model = Keyword.get(opts, :model, @default_transcription_model)
    language = Keyword.get(opts, :language, @default_transcription_language)
    batch_size = Keyword.get(opts, :batch_size, 16)
    timeout_ms = Keyword.get(opts, :timeout_ms, 10 * 60 * 1_000)

    with {:ok, prediction} <-
           Froth.Replicate.start("",
             model: model,
             audio_file: audio_url,
             align_output: true,
             language: language,
             batch_size: batch_size
           ),
         {:ok, prediction} <- Froth.Replicate.await(prediction.id, timeout_ms) do
      {:ok, normalize_transcribed_words(prediction.output)}
    end
  end

  def generate_scenes(opts) when is_list(opts) do
    descriptions = Keyword.get(opts, :descriptions, [])
    label = Keyword.get(opts, :label, "Froth Video")
    model = Keyword.get(opts, :model, @default_scene_model)
    concurrency = Keyword.get(opts, :concurrency, @default_scene_concurrency)
    timeout_ms = Keyword.get(opts, :timeout_ms, 5 * 60 * 1_000)
    embed_scenes? = Keyword.get(opts, :embed_scenes, true)

    descriptions
    |> Task.async_stream(
      fn description ->
        prompt = scene_prompt(description, label)

        with {:ok, prediction} <-
               Froth.Replicate.start(prompt,
                 model: model,
                 aspect_ratio: "9:16",
                 output_format: "jpg",
                 output_quality: 90
               ),
             {:ok, prediction} <- Froth.Replicate.await(prediction.id, timeout_ms),
             {:ok, src} <- extract_scene_src(prediction.output, embed_scenes?) do
          {:ok, %{src: src, prompt: prompt}}
        end
      end,
      max_concurrency: concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, scene}}, {:ok, acc} ->
        {:cont, {:ok, [scene | acc]}}

      {:ok, {:error, reason}}, _acc ->
        {:halt, {:error, reason}}

      {:exit, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, scenes} -> {:ok, Enum.reverse(scenes)}
      {:error, reason} -> {:error, reason}
    end
  end

  def record(html, opts \\ []) when is_binary(html) and is_list(opts) do
    with {:ok, plan} <- RenderSupport.prepare_recording(html, opts),
         {:ok, browser_id} <- Froth.Browser.checkout(label: "video #{plan.render_id}") do
      try do
        with :ok <- RenderSupport.boot_browser(browser_id, plan),
             :ok <-
               RenderSupport.render_frame_range(
                 browser_id,
                 plan,
                 0,
                 plan.frame_count - 1,
                 on_frame: fn frame_index, _frame_total ->
                   if rem(frame_index, 120) == 0 do
                     IO.puts("Rendered frame #{frame_index + 1}/#{plan.frame_count}")
                   end

                   :ok
                 end
               ),
             :ok <- RenderSupport.mux_frames(plan, opts) do
          {:ok, plan.output_path}
        end
      after
        _ = Froth.Browser.release(browser_id)
        RenderSupport.cleanup_recording(plan)
      end
    end
  end

  defp fetch_podcast_script(batch_id) do
    case Repo.get_by(Script, batch_id: batch_id) do
      %Script{} = script -> {:ok, script}
      nil -> {:error, {:podcast_not_found, batch_id}}
    end
  end

  defp prepare_podcast_audio(script, batch_id, opts) do
    cond do
      audio_path = Keyword.get(opts, :audio_path) ->
        audio_path = Path.expand(audio_path)

        if File.exists?(audio_path),
          do: {:ok, audio_path, false},
          else: {:error, :audio_not_found}

      File.exists?(default_podcast_audio_path(batch_id)) ->
        {:ok, default_podcast_audio_path(batch_id), false}

      audio_url = Keyword.get(opts, :audio_url) || script.audio_url ->
        download_audio(audio_url, "podcast-#{batch_id}")

      true ->
        {:error, :missing_audio_input}
    end
  end

  defp resolve_duration(audio_path, opts) do
    case Keyword.get(opts, :duration_s) do
      nil ->
        probe_duration(audio_path)

      duration ->
        {:ok, normalize_duration(duration)}
    end
  end

  defp resolve_words(script, duration_s, opts) do
    cond do
      words = Keyword.get(opts, :words) ->
        {:ok, normalize_word_list(words)}

      audio_url = Keyword.get(opts, :audio_url) || script.audio_url ->
        case transcribe(audio_url, opts) do
          {:ok, words} ->
            {:ok, words}

          {:error, reason} ->
            IO.puts("WhisperX failed, falling back to estimated word timings: #{inspect(reason)}")
            {:ok, estimate_words(script.script || [], duration_s)}
        end

      true ->
        IO.puts(
          "No public audio URL available for WhisperX; estimating word timings from script."
        )

        {:ok, estimate_words(script.script || [], duration_s)}
    end
  end

  defp resolve_scenes(script, opts) do
    cond do
      scenes = Keyword.get(opts, :scenes) ->
        materialize_existing_scenes(scenes, opts)

      descriptions = Keyword.get(opts, :scene_descriptions) ->
        generate_scenes(
          Keyword.merge(opts, descriptions: descriptions, label: script.label || "Podcast")
        )

      is_binary(script.cover_url) and script.cover_url != "" ->
        scene_count = scene_count(script, opts)
        materialize_existing_scenes(List.duplicate(%{src: script.cover_url}, scene_count), opts)

      true ->
        descriptions = derive_scene_descriptions(script, opts)

        case generate_scenes(
               Keyword.merge(opts, descriptions: descriptions, label: script.label || "Podcast")
             ) do
          {:ok, scenes} when scenes != [] ->
            {:ok, scenes}

          {:ok, []} ->
            {:ok, [fallback_scene(script.label || "Podcast")]}

          {:error, reason} ->
            IO.puts("Scene generation failed, using placeholder scene: #{inspect(reason)}")
            {:ok, [fallback_scene(script.label || "Podcast")]}
        end
    end
  end

  defp materialize_existing_scenes(scenes, opts) when is_list(scenes) do
    embed_scenes? = Keyword.get(opts, :embed_scenes, true)

    scenes
    |> Enum.map(fn scene ->
      src =
        scene[:src] || scene["src"] || scene[:url] || scene["url"] || scene[:path] ||
          scene["path"] || raise ArgumentError, "scene is missing src/url/path"

      with {:ok, materialized_src} <- materialize_scene_src(src, embed_scenes?) do
        {:ok, Map.put(normalize_scene_map(scene), :src, materialized_src)}
      end
    end)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, scene}, {:ok, acc} -> {:cont, {:ok, [scene | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_scene_map(scene) when is_map(scene) do
    scene
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case key do
        :start -> Map.put(acc, :start, value)
        "start" -> Map.put(acc, :start, value)
        :end -> Map.put(acc, :end, value)
        "end" -> Map.put(acc, :end, value)
        _ -> acc
      end
    end)
  end

  defp derive_scene_descriptions(script, opts) do
    rows = script.script || []
    count = scene_count(script, opts)
    chunks = chunk_rows(rows, count)
    label = script.label || "Podcast"

    Enum.map(chunks, fn chunk ->
      excerpt =
        chunk
        |> Enum.map_join(" ", fn row -> row["text"] || row[:text] || "" end)
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> String.slice(0, 220)

      if excerpt == "" do
        label
      else
        "#{label}. #{excerpt}"
      end
    end)
  end

  defp scene_count(script, opts) do
    rows = script.script || []
    explicit = Keyword.get(opts, :scene_count)

    cond do
      is_integer(explicit) and explicit > 0 ->
        explicit

      rows == [] ->
        1

      true ->
        rows
        |> length()
        |> Kernel./(3)
        |> Float.ceil()
        |> trunc()
        |> min(8)
        |> max(3)
    end
  end

  defp chunk_rows([], _count), do: [[]]

  defp chunk_rows(rows, count) do
    chunk_size =
      rows
      |> length()
      |> Kernel./(max(count, 1))
      |> Float.ceil()
      |> trunc()
      |> max(1)

    Enum.chunk_every(rows, chunk_size)
  end

  defp estimate_words(rows, duration_s) when is_list(rows) do
    words =
      rows
      |> Enum.map_join(" ", fn row -> row["text"] || row[:text] || "" end)
      |> String.split(~r/\s+/, trim: true)

    case words do
      [] ->
        []

      list ->
        seconds_per_word = duration_s / max(length(list), 1)

        Enum.with_index(list)
        |> Enum.map(fn {word, index} ->
          start_s = min(duration_s, index * seconds_per_word)
          end_s = min(duration_s, (index + 1) * seconds_per_word)
          %{word: word, start: start_s, end: max(start_s + 0.01, end_s)}
        end)
    end
  end

  defp normalize_transcribed_words(%{"segments" => segments}) when is_list(segments) do
    segments
    |> Enum.flat_map(fn segment -> segment["words"] || [] end)
    |> normalize_word_list()
  end

  defp normalize_transcribed_words(_output), do: []

  defp normalize_word_list(words) when is_list(words) do
    words
    |> Enum.map(fn word ->
      %{
        word: word[:word] || word["word"] || word[:text] || word["text"],
        start: normalize_duration(word[:start] || word["start"] || 0.0),
        end: normalize_duration(word[:end] || word["end"] || 0.0)
      }
    end)
    |> Enum.reject(fn word ->
      is_nil(word.word) or word.word == "" or word.start >= word.end
    end)
  end

  defp compose_options(script, duration_s, opts) do
    speakers = extract_speaker_segments(script)

    [
      title: script.label || Keyword.get(opts, :title, "Podcast"),
      duration_s: duration_s,
      font: Keyword.get(opts, :font, "EB Garamond"),
      word_size: Keyword.get(opts, :word_size, "5vh"),
      transition_ms: Keyword.get(opts, :transition_ms, 800),
      speakers: speakers
    ]
  end

  defp extract_speaker_segments(%{script: rows}) when is_list(rows) do
    # Estimate segment timings by distributing words across the script duration.
    # Each row has speaker + text. We estimate time per word and accumulate.
    total_words =
      rows
      |> Enum.map(fn r -> (r["text"] || "") |> String.split(~r/\s+/, trim: true) |> length() end)
      |> Enum.sum()

    if total_words == 0 do
      []
    else
      {segments, _} =
        Enum.map_reduce(rows, 0.0, fn row, cursor ->
          text = row["text"] || ""
          speaker = row["speaker"] || ""
          wc = text |> String.split(~r/\s+/, trim: true) |> length()
          # Rough estimate: 2.5 words per second for podcast speech
          duration = max(wc / 2.5, 0.5)
          seg = %{speaker: speaker, start: cursor, end: cursor + duration}
          {seg, cursor + duration}
        end)

      segments
    end
  end

  defp extract_speaker_segments(_), do: []

  defp record_options(audio_path, batch_id, duration_s, opts) do
    opts
    |> Keyword.put(:audio_path, audio_path)
    |> Keyword.put(:duration_s, duration_s)
    |> Keyword.put_new(
      :output_path,
      Path.join(RenderSupport.render_root(), "podcast_#{batch_id}.mp4")
    )
  end

  defp maybe_send_video(script, output_path, opts) do
    if Keyword.get(opts, :send_video?, true) do
      chat_id = Keyword.get(opts, :chat_id, script.chat_id)
      bot_id = Keyword.get(opts, :bot_id, @default_bot_id)
      caption = Keyword.get(opts, :caption, script.label || "Podcast video")

      if is_integer(chat_id) do
        IO.puts("Sending video to Telegram chat #{chat_id}")

        case Froth.Telegram.send_video(bot_id, chat_id, output_path, caption: caption) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:telegram_send_failed, reason}}
        end
      else
        :ok
      end
    else
      :ok
    end
  end

  defp scene_prompt(description, label) do
    [
      "Vertical 9:16 photograph, editorial quality, dramatic lighting.",
      "Single dominant subject, shallow depth of field, rich color grading.",
      "No text, no watermarks, no overlays, no UI elements.",
      "Topic: #{label}.",
      "Scene: #{description}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.trim()
  end

  defp extract_scene_src(%{"urls" => [url | _]}, embed_scenes?) when is_binary(url) do
    materialize_scene_src(url, embed_scenes?)
  end

  defp extract_scene_src(url, embed_scenes?) when is_binary(url) do
    materialize_scene_src(url, embed_scenes?)
  end

  defp extract_scene_src(output, _embed_scenes?) do
    {:error, {:invalid_scene_output, output}}
  end

  defp materialize_scene_src(src, _embed_scenes?) when not is_binary(src) do
    {:error, :invalid_scene_src}
  end

  defp materialize_scene_src("data:" <> _ = src, _embed_scenes?), do: {:ok, src}

  defp materialize_scene_src("file://" <> path, true) do
    path
    |> URI.decode()
    |> data_uri_from_file()
  end

  defp materialize_scene_src(src, true) do
    cond do
      String.starts_with?(src, ["http://", "https://"]) ->
        data_uri_from_url(src)

      Path.type(src) == :absolute and File.exists?(src) ->
        data_uri_from_file(src)

      true ->
        {:ok, src}
    end
  end

  defp materialize_scene_src(src, false), do: {:ok, src}

  defp data_uri_from_url(url) do
    case Req.get(url, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        content_type = header_value(headers, "content-type") || media_type_from_path(url)
        {:ok, "data:#{content_type};base64,#{Base.encode64(body)}"}

      {:ok, %{status: status}} ->
        {:error, {:scene_download_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp data_uri_from_file(path) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, "data:#{media_type_from_path(path)};base64,#{Base.encode64(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp header_value(headers, key) when is_list(headers) do
    Enum.find_value(headers, fn
      {header_key, value} ->
        if String.downcase(to_string(header_key)) == key do
          value |> to_string() |> String.split(";", parts: 2) |> hd()
        end

      _ ->
        nil
    end)
  end

  defp header_value(headers, key) when is_map(headers) do
    case Map.get(headers, key) || Map.get(headers, String.downcase(key)) do
      [value | _] ->
        value |> to_string() |> String.split(";", parts: 2) |> hd()

      value when is_binary(value) ->
        value |> String.split(";", parts: 2) |> hd()

      _ ->
        nil
    end
  end

  defp media_type_from_path(path) do
    MIME.from_path(path) || "image/jpeg"
  end

  defp fallback_scene(label) do
    text = URI.encode(label || "Froth Video")

    %{
      src:
        "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1080 1920'%3E%3Cdefs%3E%3ClinearGradient id='g' x1='0' y1='0' x2='1' y2='1'%3E%3Cstop offset='0%25' stop-color='%23000000'/%3E%3Cstop offset='100%25' stop-color='%23151515'/%3E%3C/linearGradient%3E%3C/defs%3E%3Crect width='1080' height='1920' fill='url(%23g)'/%3E%3Ctext x='540' y='960' text-anchor='middle' fill='white' font-family='monospace' font-size='68'%3E#{text}%3C/text%3E%3C/svg%3E"
    }
  end

  defp probe_duration(audio_path) when is_binary(audio_path) do
    case System.cmd("ffprobe", [
           "-v",
           "quiet",
           "-show_entries",
           "format=duration",
           "-of",
           "csv=p=0",
           audio_path
         ]) do
      {output, 0} ->
        case Float.parse(String.trim(output)) do
          {seconds, _} -> {:ok, seconds}
          :error -> {:error, :invalid_audio_duration}
        end

      {output, code} ->
        {:error, {:ffprobe_failed, code, output}}
    end
  end

  defp default_podcast_audio_path(batch_id) do
    "/tmp/podcast_#{batch_id}_final.mp3"
  end

  defp maybe_put_telegram_opts(opts) do
    cond do
      Keyword.has_key?(opts, :telegram) ->
        opts

      is_integer(opts[:chat_id]) ->
        Keyword.put(opts, :telegram, %{
          bot_id: Keyword.get(opts, :bot_id, @default_bot_id),
          chat_id: opts[:chat_id]
        })

      true ->
        opts
    end
  end

  defp download_audio(audio_url, render_id) when is_binary(audio_url) do
    path = Path.join(RenderSupport.render_root(), "#{render_id}.mp3")

    :ok = File.mkdir_p(RenderSupport.render_root())

    case Req.get(audio_url, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: body}} ->
        case File.write(path, body) do
          :ok -> {:ok, path, true}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{status: status}} ->
        {:error, {:audio_download_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_duration(duration) when is_integer(duration), do: duration * 1.0
  defp normalize_duration(duration) when is_float(duration), do: duration

  defp normalize_duration(duration) when is_binary(duration) do
    case Float.parse(duration) do
      {value, _} -> value
      :error -> 0.0
    end
  end

  defp normalize_duration(_duration), do: 0.0

  defp prepare_podcast_render(batch_id, opts) do
    with {:ok, script} <- fetch_podcast_script(batch_id),
         {:ok, audio_path, cleanup_audio?} <- prepare_podcast_audio(script, batch_id, opts),
         {:ok, duration_s} <- resolve_duration(audio_path, opts),
         {:ok, words} <- resolve_words(script, duration_s, opts),
         {:ok, scenes} <- resolve_scenes(script, opts) do
      html =
        compose(
          words,
          scenes,
          opts[:audio_url] || script.audio_url,
          compose_options(script, duration_s, opts)
        )

      {:ok,
       %{
         script: script,
         audio_path: audio_path,
         cleanup_audio?: cleanup_audio?,
         duration_s: duration_s,
         words: words,
         scenes: scenes,
         html: html,
         record_opts: record_options(audio_path, batch_id, duration_s, opts)
       }}
    end
  end

  defp podcast_result(prepared, batch_id, output_path) do
    %{
      batch_id: batch_id,
      duration_s: prepared.duration_s,
      output_path: output_path,
      scene_count: length(prepared.scenes),
      word_count: length(prepared.words)
    }
  end
end
