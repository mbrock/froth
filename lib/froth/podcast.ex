defmodule Froth.Podcast do
  @moduledoc """
  Generate a podcast from a script of voice segments.

  Usage:

      script = [
        {:alex, "Sigge, jag måste berätta om pjäsen."},
        {:sigge, "Vilken pjäs?"},
        {:alex, "Den jag regisserar. På Kulturhuset.", emotion: "happy"}
      ]

      Froth.Podcast.generate(script,
        chat_id: chat_id,
        label: "Alex & Sigge: Huvudskådespelaren",
        pause_ms: 300,
        language: "Swedish",
        model: "minimax/speech-2.8-hd",
        concurrency: 6
      )

  Speaker atoms (e.g. `:alex`, `:sigge`) are resolved to voice IDs
  automatically from the `voice_clones` database table.

  Runs asynchronously. Sends Telegram progress updates and the final
  stitched audio. Returns `{:ok, pid}` immediately.

  ## Finding and analyzing podcasts

      # Step 1: Search Apple Podcasts
      {:ok, results} = Froth.Podcast.search("alex och sigge")
      # => [%{name: "Alex & Sigges podcast", feed_url: "...", ...}, ...]

      # Step 2: Download an episode and host it publicly
      {:ok, ep} = Froth.Podcast.download(feed_url, "alex_sigge")
      # => %{local_path: ".../alex_sigge.mp3", public_url: "https://example.com/alex_sigge.mp3"}

      # Step 3: Ask Gemini to find voice segments for cloning
      {:ok, analysis} = Froth.Podcast.analyze_voices(ep.public_url)
      # => %{speakers: [%{name: "Alex", segments: [%{from: "07:16", ...}], ...}], raw: "..."}


  ## Script rules for TTS

  These rules apply to all podcast manuscripts. The TTS model reads text
  literally, so the script must be written for spoken delivery:

  1. **No digits.** Write all numbers as words. Years: "nittonhundrasjuttiotre"
     not "1973". Statistics: "fem tusen tre hundra sjutton" not "5 317".
     The TTS reads digits unpredictably — sometimes spelled out, sometimes
     as individual digits. Written-out numbers also read better as prose.

  2. **No caps lock.** Never use ALL CAPS for emphasis. The TTS reads caps
     as acronyms or spells them letter by letter. Use repetition, pacing,
     and word choice for intensity instead. This includes sponsor reads
     and exclamations — write "vad i helvete" not "VAD I HELVETE".

  3. **Correct Swedish orthography only.** Never use colloquial spellings:
     - "något" not "nåt"
     - "någon" not "nån"  
     - "de" / "dem" not "dom"
     - "sedan" not "sen" (when used as conjunction)
     - "skall" or "ska" not "ska'" with apostrophe
     The TTS model handles standard written Swedish well. Colloquial
     spellings produce unpredictable pronunciation and sound worse
     than letting the voice model's natural cadence carry the informality.
  """

  require Logger

  @default_model "minimax/speech-2.8-hd"
  @default_pause_ms 300
  @yt_dlp Path.expand("~/.local/bin/yt-dlp")
  @yt_cookies Path.expand("~/.config/yt_cookies.txt")
  @yt_env [{"PATH", "#{Path.expand("~/.deno/bin")}:#{System.get_env("PATH")}"}]

  defp docroot, do: Application.get_env(:froth, __MODULE__, [])[:docroot] || "/tmp/podcast"
  defp public_base, do: Application.get_env(:froth, __MODULE__, [])[:public_base] || "https://example.com"

  # --- Podcast discovery ---

  @doc """
  Search Apple Podcasts. Returns a list of matching shows.

      {:ok, results} = Froth.Podcast.search("alex och sigge")

  Options:
    * `:country` — country code (default: "se")
    * `:limit` — max results (default: 5)
  """
  def search(term, opts \\ []) do
    country = Keyword.get(opts, :country, "se")
    limit = Keyword.get(opts, :limit, 5)

    url =
      "https://itunes.apple.com/search?" <>
        URI.encode_query(
          term: term,
          media: "podcast",
          entity: "podcast",
          country: country,
          limit: to_string(limit)
        )

    req = Finch.build(:get, url)

    case Finch.request(req, Froth.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        results = Jason.decode!(body)["results"] || []

        {:ok,
         Enum.map(results, fn r ->
           %{
             name: r["collectionName"],
             artist: r["artistName"],
             feed_url: r["feedUrl"],
             artwork: r["artworkUrl600"],
             episode_count: r["trackCount"],
             genres: r["genres"]
           }
         end)}

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:apple_api, status}}

      {:error, err} ->
        {:error, err}
    end
  end

  @doc """
  List episodes from an RSS feed URL. Returns titles and audio URLs.

      {:ok, episodes} = Froth.Podcast.episodes(feed_url)

  Options:
    * `:limit` — max episodes to return (default: 10)
  """
  def episodes(feed_url, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    req = Finch.build(:get, feed_url)

    case Finch.request(req, Froth.Finch, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        items = parse_rss_items(body, limit)
        {:ok, items}

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:feed_fetch, status}}

      {:error, err} ->
        {:error, err}
    end
  end

  @doc """
  Download a podcast episode and host it on song.less.rest.

      {:ok, ep} = Froth.Podcast.download(episode_url, "alex_sigge")

  The slug determines the filename. If the file already exists it's not re-downloaded.
  Returns `{:ok, %{local_path: ..., public_url: ...}}`.
  """
  def download(episode_url, slug) do
    slug =
      slug
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "_")
      |> String.trim("_")

    filename = "#{slug}.mp3"
    local_path = Path.join(docroot(), filename)
    public_url = "#{public_base()}/#{filename}"

    if File.exists?(local_path) do
      Logger.info("Already downloaded: #{local_path}")
      {:ok, %{local_path: local_path, public_url: public_url}}
    else
      Logger.info("Downloading #{episode_url} -> #{local_path}")

      {_, exit} =
        System.cmd(
          "ffmpeg",
          [
            "-y",
            "-i",
            episode_url,
            "-c",
            "copy",
            local_path
          ],
          stderr_to_stdout: true
        )

      if exit == 0 and File.exists?(local_path) do
        {:ok, %{local_path: local_path, public_url: public_url}}
      else
        {:error, :download_failed}
      end
    end
  end

  # --- Voice analysis ---

  @doc """
  Send a publicly-hosted audio URL to Gemini 3 Pro and ask it to identify
  speakers and find clean monologue segments for voice cloning.

      {:ok, text} = Froth.Podcast.analyze_voices("https://song.less.rest/podcast.mp3")

  Returns `{:ok, gemini_text}` — the raw Gemini analysis. Charlie interprets it.
  """
  def analyze_voices(public_url) do
    prompt = """
    I need voice samples from this audio for voice cloning.

    Identify every distinct speaker. For each one:
    1. Name them (use their real name if recognizable)
    2. Briefly describe their voice (pitch, pace, tone, accent)
    3. Find 3-5 representative segments where they're speaking clearly.
       A few seconds of clean speech is enough — 5-15 seconds per segment is ideal.
       Minimal overlap or background noise preferred, but don't skip a speaker
       just because the audio is imperfect. Give precise timestamps as MM:SS-MM:SS.
    4. For each segment, quote a few words so the segment can be verified.
    """

    Froth.Analyzer.API.gemini_with_file(
      "gemini-3.1-pro-preview",
      public_url,
      "audio/mpeg",
      prompt
    )
  end

  @doc """
  Full verbatim transcription with speaker attribution and speech pattern analysis.

      {:ok, text} = Froth.Podcast.transcribe("https://song.less.rest/podcast.mp3")
      {:ok, text} = Froth.Podcast.transcribe("https://www.youtube.com/watch?v=abc123")

  Accepts audio URLs or YouTube URLs. Uses Gemini 3 Pro Preview.
  Returns the full transcript plus a detailed analysis of each speaker's
  verbal habits, filler words, rhythm, and interaction patterns.

  Options:
    * `:model` — Gemini model (default: "gemini-3.1-pro-preview")
  """
  def transcribe(url, opts \\ []) do
    model = Keyword.get(opts, :model, "gemini-3.1-pro-preview")
    mime = if youtube_url?(url), do: "video/mp4", else: "audio/mpeg"

    prompt = """
    Transcribe this entire audio word for word. Every word, every "uh", "um",
    every stammer, false start, laugh, sigh, throat-clearing, and interruption.

    Requirements:
    1. Identify every distinct speaker. Use their real name if recognizable,
       otherwise label them SPEAKER 1, SPEAKER 2, etc.
    2. Label each line with the speaker name.
    3. Mark non-speech sounds in parentheses: (laughs), (sighs), (pause),
       (clears throat), (coughs), etc.
    4. Note overlapping speech with [overlapping].
    5. Preserve ALL filler words and verbal tics exactly as spoken.

    After the full transcription, write a detailed analysis:

    SPEAKER PROFILES:
    For each speaker, describe their voice (pitch, pace, energy, accent).

    VERBAL TICS AND FILLERS:
    What filler words does each speaker use? How often? In what contexts?

    RHYTHM AND PACING:
    Who speaks faster? Who pauses more? How long are typical utterances
    before the other person jumps in?

    INTERACTION PATTERNS:
    Who leads topics? Who reacts? Who interrupts whom? How do they signal
    agreement vs disagreement? How do transitions between topics happen?

    WHAT MAKES THEM DISTINCTIVE:
    What specific habits, phrases, or patterns would you need to reproduce
    to write dialogue that sounds authentically like each speaker?
    """

    Froth.Analyzer.API.gemini_with_file(model, url, mime, prompt)
  end

  defp youtube_url?(url) do
    uri = URI.parse(url)
    uri.host in ["www.youtube.com", "youtube.com", "youtu.be", "m.youtube.com"]
  end

  # --- YouTube ---

  @doc """
  Search YouTube. Returns a list of videos with title, URL, channel, duration.

      {:ok, results} = Froth.Podcast.youtube_search("lex fridman peter thiel")
  """
  def youtube_search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    args = [
      "--cookies",
      @yt_cookies,
      "--remote-components",
      "ejs:github",
      "ytsearch#{limit}:#{query}",
      "--flat-playlist",
      "-J",
      "--no-warnings"
    ]

    case System.cmd(@yt_dlp, args, stderr_to_stdout: true, env: @yt_env) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"entries" => entries}} ->
            {:ok,
             Enum.map(entries, fn e ->
               %{
                 id: e["id"],
                 title: e["title"],
                 url: "https://www.youtube.com/watch?v=#{e["id"]}",
                 channel: e["channel"] || e["uploader"],
                 duration: e["duration"],
                 duration_string: format_yt_duration(e["duration"])
               }
             end)}

          {:ok, _} ->
            {:ok, []}

          {:error, err} ->
            {:error, {:json_parse, err}}
        end

      {output, _} ->
        {:error, {:yt_dlp, String.slice(output, 0, 500)}}
    end
  end

  @doc """
  Analyze voices in a YouTube video. Gives the YouTube URL directly to Gemini
  as a video file reference — Gemini fetches and processes it natively.

      {:ok, text} = Froth.Podcast.analyze_voices_youtube("https://www.youtube.com/watch?v=abc123")
  """
  def analyze_voices_youtube(youtube_url) do
    prompt = """
    I need voice samples from this video for voice cloning.

    Identify every distinct speaker. For each one:
    1. Name them (use their real name if recognizable)
    2. Briefly describe their voice (pitch, pace, tone, accent)
    3. Find 3-5 representative segments where they're speaking clearly.
       A few seconds of clean speech is enough — 5-15 seconds per segment is ideal.
       Minimal overlap or background noise preferred, but don't skip a speaker
       just because the audio is imperfect. Give precise timestamps as MM:SS-MM:SS.
    4. For each segment, quote a few words so the segment can be verified.
    """

    Froth.Analyzer.API.gemini_with_file(
      "gemini-3.1-pro-preview",
      youtube_url,
      "video/mp4",
      prompt
    )
  end

  @doc """
  Download audio from a YouTube video and host it on song.less.rest.

      {:ok, ep} = Froth.Podcast.download_youtube("https://www.youtube.com/watch?v=abc123", "lex_thiel")
      ep.public_url  # => "https://song.less.rest/lex_thiel.mp3"
  """
  def download_youtube(youtube_url, slug) do
    slug =
      slug
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "_")
      |> String.trim("_")

    filename = "#{slug}.mp3"
    local_path = Path.join(docroot(), filename)
    public_url = "#{public_base()}/#{filename}"

    if File.exists?(local_path) do
      Logger.info("Already downloaded: #{local_path}")
      {:ok, %{local_path: local_path, public_url: public_url}}
    else
      tmp_template = "/tmp/yt_#{slug}.%(ext)s"
      tmp_mp3 = "/tmp/yt_#{slug}.mp3"

      {output, exit} =
        System.cmd(
          @yt_dlp,
          [
            "--cookies",
            @yt_cookies,
            "--remote-components",
            "ejs:github",
            "--extract-audio",
            "--audio-format",
            "mp3",
            "--audio-quality",
            "0",
            "-o",
            tmp_template,
            youtube_url
          ],
          stderr_to_stdout: true,
          env: @yt_env
        )

      if exit == 0 and File.exists?(tmp_mp3) do
        File.cp!(tmp_mp3, local_path)
        File.rm(tmp_mp3)
        {:ok, %{local_path: local_path, public_url: public_url}}
      else
        {:error, {:yt_dlp, String.slice(output, 0, 500)}}
      end
    end
  end

  defp format_yt_duration(nil), do: nil

  defp format_yt_duration(seconds) when is_number(seconds) do
    m = div(trunc(seconds), 60)
    s = rem(trunc(seconds), 60)
    "#{m}:#{String.pad_leading(to_string(s), 2, "0")}"
  end

  # --- Voice cloning ---

  @doc """
  Clone a voice from an audio file by cutting and concatenating segments,
  hosting the result, and sending it to minimax/voice-cloning on Replicate.

      {:ok, result} = Froth.Podcast.clone_voice(
        "/path/to/episode.mp3",
        [{25, 55}, {180, 220}, {400, 430}],
        "speaker_name"
      )
      result.voice_id  # => "R8_XXXX"

  `segments` is a list of `{start_seconds, end_seconds}` tuples. They get
  concatenated into a single sample file (10s–5min, under 20MB).
  """
  def clone_voice(source_path, segments, name, opts \\ []) do
    noise_reduction = Keyword.get(opts, :noise_reduction, true)
    clone_model = Keyword.get(opts, :clone_model, "speech-2.6-hd")

    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "_")
      |> String.trim("_")

    sample_filename = "#{slug}_voice_sample.mp3"
    sample_path = Path.join(docroot(), sample_filename)
    sample_url = "#{public_base()}/#{sample_filename}"

    with :ok <- cut_and_concat(source_path, segments, sample_path),
         {:ok, prediction} <- run_voice_clone(sample_url, noise_reduction, clone_model),
         {:ok, done} <- Froth.Replicate.await(prediction.id, 300_000) do
      voice_id = get_in(done.output, ["voice_id"]) || done.output

      {:ok,
       %{
         voice_id: voice_id,
         name: name,
         prediction_id: done.id,
         sample_url: sample_url,
         sample_path: sample_path
       }}
    end
  end

  defp cut_and_concat(source_path, segments, output_path) when length(segments) == 1 do
    [{start_s, end_s}] = segments
    duration = end_s - start_s

    {_, exit} =
      System.cmd(
        "ffmpeg",
        [
          "-y",
          "-i",
          source_path,
          "-ss",
          to_string(start_s),
          "-t",
          to_string(duration),
          "-c",
          "copy",
          output_path
        ],
        stderr_to_stdout: true
      )

    if exit == 0, do: :ok, else: {:error, :ffmpeg_cut_failed}
  end

  defp cut_and_concat(source_path, segments, output_path) do
    tmp_dir = "/tmp/voice_clone_#{System.unique_integer([:positive])}"
    File.mkdir_p!(tmp_dir)

    # Cut each segment
    seg_paths =
      segments
      |> Enum.with_index()
      |> Enum.map(fn {{start_s, end_s}, i} ->
        seg_path = Path.join(tmp_dir, "seg_#{String.pad_leading(to_string(i), 3, "0")}.mp3")
        duration = end_s - start_s

        {_, 0} =
          System.cmd(
            "ffmpeg",
            [
              "-y",
              "-i",
              source_path,
              "-ss",
              to_string(start_s),
              "-t",
              to_string(duration),
              "-c",
              "copy",
              seg_path
            ],
            stderr_to_stdout: true
          )

        seg_path
      end)

    # Concatenate
    concat_path = Path.join(tmp_dir, "concat.txt")
    concat_content = Enum.map_join(seg_paths, "\n", &"file '#{&1}'")
    File.write!(concat_path, concat_content)

    {_, exit} =
      System.cmd(
        "ffmpeg",
        [
          "-y",
          "-f",
          "concat",
          "-safe",
          "0",
          "-i",
          concat_path,
          "-c",
          "copy",
          output_path
        ],
        stderr_to_stdout: true
      )

    # Cleanup
    File.rm_rf!(tmp_dir)

    if exit == 0, do: :ok, else: {:error, :ffmpeg_concat_failed}
  end

  defp run_voice_clone(sample_url, noise_reduction, clone_model) do
    # Build input directly to avoid the :model keyword conflict in Replicate.start
    input = %{
      voice_file: sample_url,
      need_noise_reduction: noise_reduction
    }

    input = if clone_model, do: Map.put(input, :model, clone_model), else: input

    Froth.Replicate.create_prediction("minimax/voice-cloning", input)
    |> case do
      {:ok, %{"id" => replicate_id, "status" => status} = resp} ->
        attrs = %{
          model: "minimax/voice-cloning",
          prompt: "voice_clone",
          input: input,
          status: status,
          replicate_id: replicate_id,
          output: resp["output"],
          error: resp["error"]
        }

        %Froth.Replicate.Prediction{}
        |> Froth.Replicate.Prediction.changeset(attrs)
        |> Froth.Repo.insert()

      {:error, _} = err ->
        err
    end
  end

  defp parse_rss_items(xml, limit) do
    Regex.scan(~r/<item>(.+?)<\/item>/s, xml)
    |> Enum.take(limit)
    |> Enum.with_index()
    |> Enum.map(fn {[_, item], i} ->
      title =
        case Regex.run(~r/<title>(?:<!\[CDATA\[)?(.+?)(?:\]\]>)?<\/title>/, item) do
          [_, t] -> String.trim(t)
          _ -> "Episode #{i}"
        end

      url =
        case Regex.run(~r/enclosure[^>]+url="([^"]+)"/, item) do
          [_, u] -> u
          _ -> nil
        end

      duration =
        case Regex.run(~r/<itunes:duration>([^<]+)</, item) do
          [_, d] -> String.trim(d)
          _ -> nil
        end

      %{index: i, title: title, url: url, duration: duration}
    end)
    |> Enum.filter(& &1.url)
  end

  @doc """
  Generate a podcast asynchronously. Returns `{:ok, pid}`.

  ## Options

    * `:chat_id` — Telegram chat to send progress/result (required)
    * `:label` — human label for the podcast (default: "Podcast")
    * `:pause_ms` — silence between segments in ms (default: 300)
    * `:language` — language_boost value (default: "Swedish")
    * `:model` — Replicate TTS model (default: minimax/speech-2.8-hd)
    * `:concurrency` — max parallel TTS jobs (default: 6)
    * `:bot_token` — Telegram bot token (default: from env)
  """
  def generate(script, opts \\ []) do
    chat_id = Keyword.fetch!(opts, :chat_id)
    label = Keyword.get(opts, :label, "Podcast")
    model = Keyword.get(opts, :model, @default_model)
    pause_ms = Keyword.get(opts, :pause_ms, @default_pause_ms)
    language = Keyword.get(opts, :language, "Swedish")
    bot_token = Keyword.get(opts, :bot_token)

    speakers =
      script
      |> Enum.flat_map(fn
        {:file, _path} -> []
        {speaker, _text} -> [speaker]
        {speaker, _text, _opts} -> [speaker]
      end)
      |> Enum.uniq()

    voices = Froth.VoiceClone.resolve(speakers)

    batch_id = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    total = length(script)

    # Save the script to the database
    script_rows =
      Enum.map(script, fn item ->
        case normalize_item(item) do
          {:file, path, _} ->
            %{"speaker" => "file", "text" => path}

          {speaker, text, seg_opts} ->
            row = %{"speaker" => to_string(speaker), "text" => text}
            emotion = Keyword.get(seg_opts, :emotion)
            if emotion, do: Map.put(row, "emotion", emotion), else: row
        end
      end)

    {:ok, _} =
      %Froth.Podcast.Script{}
      |> Froth.Podcast.Script.changeset(%{
        batch_id: batch_id,
        label: label,
        chat_id: chat_id,
        script: script_rows,
        opts: %{model: model, pause_ms: pause_ms, language: language},
        status: "queued"
      })
      |> Froth.Repo.insert()

    # Split into file embeds (copy immediately) and TTS jobs
    {jobs, _} =
      script
      |> Enum.with_index()
      |> Enum.reduce({[], 0}, fn {item, idx}, {acc, _} ->
        case normalize_item(item) do
          {:file, path, _} ->
            # Copy the file to the segment path immediately
            seg_path = Froth.Podcast.TtsWorker.segment_path(batch_id, idx)
            File.cp!(path, seg_path)
            # Insert a pre-completed job so the stitch worker counts it
            args = %{
              "batch_id" => batch_id,
              "index" => idx,
              "speaker" => "file",
              "text" => path,
              "voice_id" => "file",
              "model" => model,
              "language" => language,
              "chat_id" => chat_id,
              "label" => label,
              "pause_ms" => pause_ms,
              "is_file" => true
            }

            args = if bot_token, do: Map.put(args, "bot_token", bot_token), else: args
            job = Froth.Podcast.TtsWorker.new(args)
            {[job | acc], 0}

          {speaker, text, seg_opts} ->
            voice_id = Map.fetch!(voices, speaker)
            emotion = Keyword.get(seg_opts, :emotion)

            args = %{
              "batch_id" => batch_id,
              "index" => idx,
              "speaker" => to_string(speaker),
              "text" => text,
              "voice_id" => voice_id,
              "model" => model,
              "language" => language,
              "chat_id" => chat_id,
              "label" => label,
              "pause_ms" => pause_ms
            }

            args = if emotion, do: Map.put(args, "emotion", emotion), else: args
            args = if bot_token, do: Map.put(args, "bot_token", bot_token), else: args
            {[Froth.Podcast.TtsWorker.new(args) | acc], 0}
        end
      end)

    Oban.insert_all(Enum.reverse(jobs))

    send_progress(
      bot_token || System.get_env("TELEGRAM_BOT_TOKEN"),
      chat_id,
      "#{label} — queued #{total} segments (batch #{batch_id})"
    )

    {:ok, batch_id}
  end

  # --- Helpers ---

  defp normalize_item({:file, path}) when is_binary(path),
    do: {:file, path, []}

  defp normalize_item({speaker, text}) when is_atom(speaker) and is_binary(text),
    do: {speaker, text, []}

  defp normalize_item({speaker, text, opts})
       when is_atom(speaker) and is_binary(text) and is_list(opts),
       do: {speaker, text, opts}

  defp send_progress(_bot_token, chat_id, text) do
    Froth.Telegram.send("charlie", %{
      "@type" => "sendMessage",
      "chat_id" => chat_id,
      "input_message_content" => %{
        "@type" => "inputMessageText",
        "text" => %{"@type" => "formattedText", "text" => text}
      }
    })
  end
end
