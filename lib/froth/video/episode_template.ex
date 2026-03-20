defmodule Froth.Video.EpisodeTemplate do
  @moduledoc false

  def render(words, scenes, audio_url, opts \\ [])
      when is_list(words) and is_list(scenes) and is_list(opts) do
    duration_s = Keyword.get(opts, :duration_s, infer_duration(words))
    title = Keyword.get(opts, :title, "Froth Video")
    font = Keyword.get(opts, :font, "EB Garamond")
    word_size = Keyword.get(opts, :word_size, "5vh")
    transition_ms = Keyword.get(opts, :transition_ms, 1200)
    speakers = Keyword.get(opts, :speakers, [])

    normalized_words = normalize_words(words)
    words_with_speakers = assign_speakers(normalized_words, speakers)
    normalized_scenes = normalize_scenes(scenes, duration_s)

    ken_burns_directions = [
      "zoom-in",
      "zoom-out",
      "pan-left",
      "pan-right",
      "zoom-in-slow",
      "pan-up"
    ]

    scenes_with_kb =
      normalized_scenes
      |> Enum.with_index()
      |> Enum.map(fn {scene, i} ->
        Map.put(
          scene,
          :ken_burns,
          Enum.at(ken_burns_directions, rem(i, length(ken_burns_directions)))
        )
      end)

    data =
      %{
        title: title,
        duration_s: duration_s,
        transition_ms: transition_ms,
        words: words_with_speakers,
        scenes: scenes_with_kb
      }
      |> Jason.encode!()

    audio_markup =
      case audio_url do
        nil -> ""
        url -> ~s(<audio id="episode-audio" preload="auto" src="#{html_escape(url)}"></audio>)
      end

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <title>#{html_escape(title)}</title>
        <style>
          @import url('https://fonts.googleapis.com/css2?family=EB+Garamond:ital,wght@0,400;0,500;0,600;0,700;0,800;1,400;1,500&family=Cormorant+Garamond:wght@300;400;500;600;700&display=swap');

          :root {
            --word-size: #{word_size};
            --font-family: "#{font}", "Cormorant Garamond", Georgia, "Times New Roman", serif;
          }

          * { box-sizing: border-box; }

          html, body {
            margin: 0;
            width: 100%;
            height: 100%;
            background: #000;
            overflow: hidden;
            font-family: var(--font-family);
          }

          body.recording #debug { display: none; }

          #video {
            position: relative;
            width: 100vw;
            height: 100vh;
            background: #000;
            overflow: hidden;
          }

          #scenes {
            position: absolute;
            inset: 0;
          }

          .scene {
            position: absolute;
            inset: -10%;
            width: 120%;
            height: 120%;
            background-position: center;
            background-size: cover;
            background-repeat: no-repeat;
            opacity: 0;
            will-change: opacity, transform;
            transition: none;
          }

          #transcript {
            position: absolute;
            bottom: 0;
            left: 0;
            right: 0;
            height: 45vh;
            overflow: hidden;
            z-index: 10;
            padding: 0 6vw 8vh;
            mask-image: linear-gradient(
              to bottom,
              transparent 0%,
              black 25%,
              black 80%,
              transparent 100%
            );
            -webkit-mask-image: linear-gradient(
              to bottom,
              transparent 0%,
              black 25%,
              black 80%,
              transparent 100%
            );
          }

          #transcript-inner {
            transition: transform 0.6s cubic-bezier(0.25, 0.1, 0.25, 1.0);
          }

          .speaker-block {
            margin-bottom: 1.5vh;
          }

          .speaker-label {
            font-size: 2vh;
            font-weight: 400;
            font-variant: small-caps;
            letter-spacing: 0.15em;
            color: rgba(255, 255, 255, 0.35);
            margin-bottom: 0.5vh;
            text-shadow: 0 1px 6px rgba(0,0,0,0.8);
          }

          .speaker-text {
            line-height: 1.4;
          }

          .word {
            font-size: var(--word-size);
            font-weight: 400;
            color: rgba(255, 255, 255, 0.18);
            letter-spacing: 0.01em;
            transition: color 0.15s ease;
            text-shadow: 0 2px 12px rgba(0,0,0,0.9), 0 0 40px rgba(0,0,0,0.7);
            display: inline;
          }

          .word.active {
            color: #ffd700;
          }

          .word.spoken {
            color: rgba(255, 255, 255, 0.5);
          }

          .word-space {
            display: inline;
            width: 0.35em;
            font-size: var(--word-size);
          }

          #title-overlay {
            position: absolute;
            top: 5vh;
            left: 0;
            right: 0;
            text-align: center;
            font-size: 2.2vh;
            font-weight: 400;
            font-variant: small-caps;
            letter-spacing: 0.25em;
            color: rgba(255, 255, 255, 0.25);
            z-index: 10;
            text-shadow: 0 1px 8px rgba(0,0,0,0.8);
          }

          #vignette {
            position: absolute;
            inset: 0;
            background: linear-gradient(
              to bottom,
              rgba(0,0,0,0.35) 0%,
              rgba(0,0,0,0.0) 20%,
              rgba(0,0,0,0.0) 45%,
              rgba(0,0,0,0.6) 70%,
              rgba(0,0,0,0.92) 100%
            );
            z-index: 5;
            pointer-events: none;
          }

          #debug {
            position: absolute;
            left: 24px;
            right: 24px;
            bottom: 24px;
            display: flex;
            justify-content: space-between;
            font-size: 14px;
            color: rgba(255, 255, 255, 0.3);
            font-family: monospace;
            z-index: 20;
          }

          #play-overlay {
            position: absolute;
            inset: 0;
            display: flex;
            align-items: center;
            justify-content: center;
            z-index: 30;
            cursor: pointer;
            background: rgba(0,0,0,0.4);
          }
          #play-overlay.hidden { display: none; }
          #play-overlay::after {
            content: '\u25b6';
            font-size: 10vh;
            color: rgba(255,255,255,0.7);
            text-shadow: 0 2px 20px rgba(0,0,0,0.5);
          }

          #progress-bar {
            position: absolute;
            bottom: 0;
            left: 0;
            right: 0;
            height: 3px;
            background: rgba(255, 255, 255, 0.08);
            z-index: 25;
            cursor: pointer;
          }

          #progress-fill {
            height: 100%;
            background: rgba(255, 215, 0, 0.6);
            width: 0%;
            transition: width 0.3s linear;
          }

          #pause-indicator {
            position: absolute;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%) scale(0);
            font-size: 8vh;
            color: rgba(255, 255, 255, 0.6);
            z-index: 25;
            pointer-events: none;
            transition: transform 0.15s ease, opacity 0.3s ease;
            opacity: 0;
            text-shadow: 0 2px 20px rgba(0,0,0,0.5);
          }

          #pause-indicator.show {
            transform: translate(-50%, -50%) scale(1);
            opacity: 1;
          }

          #video { cursor: pointer; }

        </style>
      </head>
      <body>
        <div id="video">
          <div id="scenes"></div>
          <div id="vignette"></div>
          <div id="title-overlay">#{html_escape(title)}</div>
          <div id="transcript"><div id="transcript-inner"></div></div>
          <div id="play-overlay"></div>
          <div id="progress-bar"><div id="progress-fill"></div></div>
          <div id="pause-indicator">❚❚</div>
          <div id="debug">
            <span id="debug-time">0.00</span>
            <span id="debug-word-count">0</span>
          </div>
          #{audio_markup}
        </div>
        <script>
          (() => {
            const data = #{data};
            const params = new URLSearchParams(window.location.search);
            const recording = params.get("record") === "1";
            if (recording) document.body.classList.add("recording");

            const scenesRoot = document.getElementById("scenes");
            const transcript = document.getElementById("transcript");
            const transcriptInner = document.getElementById("transcript-inner");
            const debugTimeEl = document.getElementById("debug-time");
            const debugWordCountEl = document.getElementById("debug-word-count");
            const audioEl = document.getElementById("episode-audio");
            const playOverlay = document.getElementById("play-overlay");

            if (recording || !audioEl) {
              playOverlay.classList.add("hidden");
            }

            // Build scene elements
            const sceneEls = data.scenes.map((scene, i) => {
              const el = document.createElement("div");
              el.className = "scene";
              el.style.backgroundImage = `url('${scene.src}')`;
              scenesRoot.appendChild(el);
              return el;
            });

            // Build transcript: group words by speaker into blocks
            const wordEls = [];
            let currentSpeaker = null;
            let currentBlock = null;
            let currentText = null;

            data.words.forEach((w, i) => {
              const speaker = w.speaker || "";
              if (speaker !== currentSpeaker) {
                currentSpeaker = speaker;
                currentBlock = document.createElement("div");
                currentBlock.className = "speaker-block";
                if (speaker) {
                  const label = document.createElement("div");
                  label.className = "speaker-label";
                  label.textContent = speaker;
                  currentBlock.appendChild(label);
                }
                currentText = document.createElement("div");
                currentText.className = "speaker-text";
                currentBlock.appendChild(currentText);
                transcriptInner.appendChild(currentBlock);
              }
              if (i > 0 && w.speaker === data.words[i-1].speaker) {
                const space = document.createTextNode(" ");
                currentText.appendChild(space);
              }
              const span = document.createElement("span");
              span.className = "word";
              span.dataset.wordIndex = i;
              span.textContent = w.text;
              currentText.appendChild(span);
              wordEls.push(span);
            });

            // Preload images
            const imageReady = Promise.all(
              data.scenes.map((scene, i) => new Promise((resolve) => {
                const img = new Image();
                img.onload = () => resolve(true);
                img.onerror = () => resolve(false);
                setTimeout(() => resolve(false), 8000);
                img.src = scene.src;
              }))
            );

            const sceneReadyWithFallback = Promise.race([
              imageReady,
              new Promise(resolve => setTimeout(() => resolve([]), 10000))
            ]);

            function findCurrentWord(seconds) {
              let best = -1;
              for (let i = 0; i < data.words.length; i++) {
                const w = data.words[i];
                if (seconds >= w.start - 0.05) best = i;
                if (w.start > seconds + 0.3) break;
              }
              return best;
            }

            let lastWordIdx = -1;

            function renderAt(seconds) {
              const safeSeconds = Math.max(0, Math.min(seconds, data.duration_s));
              const wordIdx = findCurrentWord(safeSeconds);

              // Update word highlights
              if (wordIdx !== lastWordIdx) {
                wordEls.forEach((el, i) => {
                  if (i === wordIdx) {
                    el.classList.add("active");
                    el.classList.remove("spoken");
                  } else if (i < wordIdx) {
                    el.classList.remove("active");
                    el.classList.add("spoken");
                  } else {
                    el.classList.remove("active");
                    el.classList.remove("spoken");
                  }
                });

                // Scroll to active word
                if (wordIdx >= 0 && wordEls[wordIdx]) {
                  const el = wordEls[wordIdx];
                  const containerH = transcript.offsetHeight;
                  const targetY = el.offsetTop - containerH * 0.6;
                  transcriptInner.style.transform = `translateY(${-Math.max(0, targetY)}px)`;
                }
                lastWordIdx = wordIdx;
              }

              // Update scenes
              sceneEls.forEach((el, index) => {
                const scene = data.scenes[index];
                el.style.opacity = opacityForScene(scene, index, safeSeconds).toFixed(4);
                el.style.transform = kenBurnsTransform(scene, safeSeconds);
              });

              debugTimeEl.textContent = safeSeconds.toFixed(2);
              debugWordCountEl.textContent = `${data.words.length} words`;

              return { seconds: safeSeconds, word: wordIdx >= 0 ? data.words[wordIdx].text : null };
            }

            function kenBurnsTransform(scene, seconds) {
              const duration = scene.end - scene.start;
              const progress = Math.max(0, Math.min(1, (seconds - scene.start) / duration));
              const kb = scene.ken_burns || "zoom-in";
              const ease = progress < 0.5 ? 2 * progress * progress : 1 - Math.pow(-2 * progress + 2, 2) / 2;

              switch(kb) {
                case "zoom-in":
                  return `scale(${1 + ease * 0.1})`;
                case "zoom-out":
                  return `scale(${1.1 - ease * 0.1})`;
                case "zoom-in-slow":
                  return `scale(${1 + ease * 0.05})`;
                case "pan-left":
                  return `scale(1.04) translateX(${-ease * 3}%)`;
                case "pan-right":
                  return `scale(1.04) translateX(${ease * 3}%)`;
                case "pan-up":
                  return `scale(1.04) translateY(${-ease * 2.5}%)`;
                default:
                  return `scale(${1 + ease * 0.07})`;
              }
            }

            function opacityForScene(scene, index, seconds) {
              const transition = data.transition_ms / 1000;
              const next = data.scenes[index + 1];
              if (seconds < scene.start || seconds >= scene.end) return 0;
              const fadeInEnd = scene.start + transition * 0.5;
              let opacity = 1;
              if (seconds < fadeInEnd && index > 0) {
                opacity = Math.min(1, (seconds - scene.start) / (transition * 0.5));
              }
              if (!next) return opacity;
              const fadeStart = Math.max(scene.start, next.start - transition);
              if (seconds < fadeStart) return opacity;
              const progress = (seconds - fadeStart) / Math.max(next.start - fadeStart, 0.0001);
              return Math.max(0, Math.min(1, (1 - progress) * opacity));
            }

            let rafId = null;

            function previewTick() {
              if (!audioEl) return;
              renderAt(audioEl.currentTime || 0);
              if (!audioEl.paused) rafId = window.requestAnimationFrame(previewTick);
            }

            function playPreview() {
              if (!audioEl) return Promise.resolve(false);
              if (rafId) window.cancelAnimationFrame(rafId);
              playOverlay.classList.add("hidden");
              return audioEl.play().then(() => {
                rafId = window.requestAnimationFrame(previewTick);
                return true;
              });
            }

            const progressBar = document.getElementById("progress-bar");
            const progressFill = document.getElementById("progress-fill");
            const pauseIndicator = document.getElementById("pause-indicator");

            let isPlaying = false;
            let pauseTimeout = null;

            function showPauseIndicator(icon) {
              pauseIndicator.textContent = icon;
              pauseIndicator.classList.add("show");
              clearTimeout(pauseTimeout);
              pauseTimeout = setTimeout(() => pauseIndicator.classList.remove("show"), 600);
            }

            function togglePlayPause() {
              if (!audioEl) return;
              if (audioEl.paused) {
                playOverlay.classList.add("hidden");
                audioEl.play().then(() => {
                  isPlaying = true;
                  if (rafId) window.cancelAnimationFrame(rafId);
                  rafId = window.requestAnimationFrame(previewTick);
                  showPauseIndicator("\u25b6");
                });
              } else {
                audioEl.pause();
                isPlaying = false;
                showPauseIndicator("\u275a\u275a");
              }
            }

            // Click anywhere on video to play/pause
            document.getElementById("video").addEventListener("click", (e) => {
              if (e.target.closest("#progress-bar")) return;
              togglePlayPause();
            });

            // Progress bar: click to seek
            progressBar.addEventListener("click", (e) => {
              if (!audioEl) return;
              const rect = progressBar.getBoundingClientRect();
              const pct = (e.clientX - rect.left) / rect.width;
              audioEl.currentTime = pct * data.duration_s;
              renderAt(audioEl.currentTime);
            });

            // Update progress bar in the tick
            const origTick = previewTick;
            previewTick = function() {
              if (!audioEl) return;
              renderAt(audioEl.currentTime || 0);
              const pct = ((audioEl.currentTime || 0) / data.duration_s * 100).toFixed(2);
              progressFill.style.width = pct + "%";
              if (!audioEl.paused) rafId = window.requestAnimationFrame(previewTick);
            };

            if (audioEl) {
              audioEl.addEventListener("ended", () => {
                isPlaying = false;
                document.dispatchEvent(new CustomEvent("playback-ended"));
                playOverlay.classList.remove("hidden");
                progressFill.style.width = "100%";
              });
            }

            window.FrothVideo = { data, ready: false, renderAt, playPreview: togglePlayPause };
            renderAt(0);
            sceneReadyWithFallback.finally(() => { window.FrothVideo.ready = true; });
          })();
        </script>
      </body>
    </html>
    """
  end

  # Assign speaker names to words by matching timestamps to script segments
  defp assign_speakers(words, []), do: Enum.map(words, &Map.put(&1, :speaker, ""))

  defp assign_speakers(words, speakers) when is_list(speakers) do
    # speakers is a list of %{speaker: "name", start: float, end: float}
    Enum.map(words, fn word ->
      speaker =
        Enum.find_value(speakers, "", fn seg ->
          if word.start >= seg.start - 0.1 and word.start <= seg.end + 0.1 do
            seg.speaker
          end
        end)

      Map.put(word, :speaker, speaker)
    end)
  end

  defp group_into_phrases(words, gap_threshold) do
    words
    |> Enum.with_index()
    |> Enum.chunk_while(
      [],
      fn {word, idx}, acc ->
        case acc do
          [] ->
            {:cont, [{word, idx}]}

          [{prev_word, _} | _] ->
            if word.start - prev_word.end > gap_threshold or length(acc) >= 8 do
              {:cont, Enum.reverse(acc), [{word, idx}]}
            else
              {:cont, [{word, idx} | acc]}
            end
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.map(fn items ->
      word_indices = Enum.map(items, fn {_, idx} -> idx end)
      words_in_phrase = Enum.map(items, fn {w, _} -> w end)

      %{
        start: List.first(words_in_phrase).start,
        end: List.last(words_in_phrase).end,
        word_indices: word_indices
      }
    end)
  end

  defp normalize_words(words) do
    Enum.map(words, fn word ->
      %{
        text: word_value(word, [:word, "word", :text, "text"]),
        start: word_value(word, [:start, "start"]) |> to_float(),
        end: word_value(word, [:end, "end"]) |> to_float()
      }
    end)
  end

  defp normalize_scenes([], duration_s) do
    [
      %{
        src:
          "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1080 1920'%3E%3Crect width='1080' height='1920' fill='black'/%3E%3C/svg%3E",
        start: 0.0,
        end: duration_s
      }
    ]
  end

  defp normalize_scenes(scenes, duration_s) do
    if Enum.all?(scenes, &Map.has_key?(&1, :start)) do
      scenes
    else
      count = length(scenes)
      per = duration_s / count

      scenes
      |> Enum.with_index()
      |> Enum.map(fn {scene, i} ->
        Map.merge(scene, %{start: i * per, end: (i + 1) * per})
      end)
    end
  end

  defp word_value(word, keys) when is_map(word) do
    Enum.find_value(keys, fn k -> Map.get(word, k) end)
  end

  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v * 1.0
  defp to_float(v) when is_binary(v), do: String.to_float(v)
  defp to_float(nil), do: 0.0

  defp infer_duration(words) do
    case words do
      [] -> 10.0
      _ -> words |> Enum.map(fn w -> word_value(w, [:end, "end"]) |> to_float() end) |> Enum.max()
    end
  end

  defp html_escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
