# Browser Video Pipeline

This should sit on top of the more general distributed execution fabric
described in `talents/distributed-execution-fabric.md`.

Render podcast episodes as videos by recording a
browser that plays an HTML page designed to be
recorded. The DOM is the timeline. The stylesheet
is the edit. The browser is the camera.

Replaces the current pipeline (Flux images + ffmpeg
concat + ASS subtitles) with a single Chrome instance
rendering a self-contained HTML episode at 1080x1920.

## Architecture

The pipeline has four stages. Each is independent.
All live in Froth.Video.

### 1. TRANSCRIBE

Input: podcast audio URL (MP3)
Output: word-level timestamps (JSON)

    {:ok, words} = Froth.Video.transcribe(audio_url)
    # => [%{word: "So", start: 0.268, end: 0.488}, ...]

Uses victor-upmeet/whisperx on Replicate. This
already works. Wrap the existing WhisperX call.

### 2. SCENE

Input: podcast script or label + segment count
Output: list of image URLs (portrait, 9:16)

    {:ok, urls} = Froth.Video.generate_scenes(
      label: "The XPath Hour",
      descriptions: [
        "An XML tree glowing neon blue...",
        "A Latvian cathedral made of XSLT..."
      ]
    )

Uses black-forest-labs/flux-1.1-pro on Replicate.
All images generated in parallel. Aspect ratio MUST
be 9:16 (portrait). Images are downloaded to local
paths for embedding as data URIs or serving via the
Phoenix app.

### 3. COMPOSE

Input: words + scenes + audio URL + options
Output: a self-contained HTML document (string)

    html = Froth.Video.compose(words, scenes, audio_url,
      title: "The XPath Hour",
      font: "JetBrains Mono",
      word_size: "7vh",
      scene_transition: "crossfade",
      transition_ms: 800
    )

The HTML document IS the video. It contains:

- A full-viewport container at exactly 1080x1920
- Scene images as absolutely positioned backgrounds
  with CSS crossfade transitions timed to scene
  boundaries
- A centered word display that shows one word at a
  time, timed to the WhisperX timestamps
- An <audio> element with the podcast MP3
- A JavaScript renderer that exposes:
  - window.FrothVideo.renderAt(seconds)
  - window.FrothVideo.playPreview()
- Preview mode uses requestAnimationFrame and
  audio.currentTime
- Record mode does NOT rely on real-time playback;
  the recorder calls renderAt(frame_time) directly
- A "recording" class on body when ?record=1 is in
  the URL (hides any debug UI)

The composition is pure: words + scenes + config in,
HTML string out. No side effects. No database. No
network calls. This is the XSLT transformation.

Important distinction:
- Preview timing may be driven by audio.currentTime
- Final render timing MUST be driven by renderAt(t)
  so the export is deterministic

Typography rules:
- Word text: white, bold, uppercase
- Font: JetBrains Mono (already installed)
- Text shadow: 0 0 0 4px black (clean outline)
- NO glow layers, NO cyan, NO colored outlines
- Centered vertically and horizontally
- Size: 7vh (scales with viewport)

Scene transition rules:
- CSS opacity crossfade, 800ms default
- Scene boundaries at equal time intervals
  (total_duration / num_scenes) unless overridden
- z-index layering: scenes behind, words in front

### 4. RECORD

Input: HTML string or URL + audio duration
Output: MP4 file path

    {:ok, path} = Froth.Video.record(html,
      duration_s: 253,
      width: 1080,
      height: 1920,
      fps: 24
    )

This is the new part. The recording pipeline.
Canonical path: deterministic frame-by-frame render.

a) Start a Froth.Browser lease
b) Set viewport to 1080x1920 via CDP:
   Emulation.setDeviceMetricsOverride with
   width=1080, height=1920, deviceScaleFactor=1
c) Load the composed HTML as a full document
   (NOT via document.documentElement.innerHTML;
   scripts must execute)
d) For each frame at 24fps:
   - frame_time = frame_index / fps
   - call window.FrothVideo.renderAt(frame_time)
   - take a screenshot via Page.captureScreenshot
   - write frame_000001.png etc.
e) Assemble frames + audio via ffmpeg:
   ffmpeg -y -framerate 24 -i frame_%06d.png \
     -i podcast.mp3 \
     -c:v libx264 -preset fast -crf 23 \
     -pix_fmt yuv420p \
     -c:a aac -b:a 192k \
     -shortest output.mp4
f) Release browser, clean up frames, return path

IMPORTANT: The audio in the HTML does NOT need to
play through speakers. Chrome headless with --mute-
audio is fine. The audio element is only used for
manual preview.
The actual audio track in the final video comes
from the original MP3 via ffmpeg mux.

OPTIONAL PREVIEW MODE: If we want live monitoring
while the page runs in real time, add a screencast
path around Page.startScreencast. Treat that as a
preview/debug feature, not the source of truth for
final export.

## Integration with Froth.Podcast

The hourly update already produces:
- A podcast script (speaker + text segments)
- A rendered audio file (MP3)
- A label and batch_id

After the audio is stitched, Charlie can enqueue:

    Froth.Video.from_podcast(batch_id,
      scene_descriptions: [...],
      chat_id: chat_id
    )

Which runs transcribe → scene → compose → record
as a background task and sends the final MP4 to the
chat. This replaces the current manual pipeline in
Charlie’s eval.

## Froth.Browser requirements

The Browser subsystem needs these additions:

1. VIEWPORT CONTROL
   Add Froth.Browser.set_viewport(browser_id, opts)
   that calls Emulation.setDeviceMetricsOverride.
   Needed to render at exactly 1080x1920 regardless
   of the default Chrome window size.

   def set_viewport(browser_ref, opts \\ []) do
     width = Keyword.get(opts, :width, 1080)
     height = Keyword.get(opts, :height, 1920)
     scale = Keyword.get(opts, :device_scale_factor, 1)
     # CDP command via the instance
   end

2. SAFE FULL-DOCUMENT LOAD
   Add Froth.Browser.set_content(browser_id, html)
   or equivalent. This must load a full HTML document
   and allow inline scripts to execute.

3. SCREENCAST SUPPORT (optional, preview only)
   If using the screencast approach, add:
   - start_screencast(browser_id, opts)
   - stop_screencast(browser_id)
   - on_screencast_frame(browser_id, callback)
   These wrap Page.startScreencast, Page.stop-
   Screencast, and the Page.screencastFrame event.

## File locations

- Module: lib/froth/video.ex
- HTML template: lib/froth/video/episode_template.ex
  (EEx or heredoc — returns HTML string)
- Browser additions: lib/froth/browser/instance.ex

## What already exists and works

- Froth.Browser: checkout, eval, screenshot, click,
  type, info, release
- Froth.Podcast: generate, stitch, TTS pipeline
- Froth.Replicate: start, await (WhisperX + Flux)
- Chrome: installed at /usr/bin/google-chrome
- ffmpeg: installed, H.264 + AAC capable
- JetBrains Mono: installed in ~/.local/share/fonts
- WhisperX on Replicate: tested, returns word-level
  timestamps with alignment

## What does NOT exist yet

- Viewport control (Emulation.setDeviceMetrics)
- Safe full-document load for arbitrary HTML
- Deterministic frame-by-frame capture
- Optional screencast preview
- The HTML episode template
- The Froth.Video module

## Design principles

- The HTML is the video. If it looks right in a
  browser window at 1080x1920, it IS right.
- No ffmpeg for visual effects. All transitions,
  typography, and animation are CSS. ffmpeg only
  muxes frames + audio into a container.
- The compose step is pure. Test it by opening the
  HTML in a browser manually. What you see is what
  gets recorded.
- Portrait (9:16) always. 1080x1920. No exceptions.
- Final export is deterministic. renderAt(t) is the
  source of truth for recorded frames.
- audio.currentTime is for preview only.

Created: 2026-03-20
