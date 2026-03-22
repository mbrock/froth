# Browser Video Pipeline

Render podcast episodes as videos by recording a browser
that plays an HTML page designed to be recorded. The DOM
is the timeline. The stylesheet is the edit. The browser
is the camera.

Replaces the old pipeline (Flux images + ffmpeg concat +
ASS subtitles) with a single Chrome instance rendering a
self-contained HTML episode at 1080x1920.

## Architecture

Four stages. Each independent. All in Froth.Video.

### 1. TRANSCRIBE

    {:ok, words} = Froth.Video.transcribe(audio_url)
    # => [%{word: "So", start: 0.268, end: 0.488}, ...]

Uses vaibhavs10/incredibly-fast-whisper on Replicate (always warm)
   Previously: victor-upmeet/whisperx (cold start issues).
Input must be a publicly accessible URL.

### 2. GENERATE SCENES

    {:ok, urls} = Froth.Video.generate_scenes(
      label: "The XPath Hour",
      descriptions: ["An XML tree...", "A cathedral..."]
    )

Uses Flux 2 Pro (black-forest-labs/flux-2-pro) as of
2026-03-22. Previously Flux 1.1 Pro. Always 9:16 portrait.
All images fire in parallel.

### 3. COMPOSE

    html = Froth.Video.compose(words, scenes, audio_url,
      title: "Episode Title",
      font: "EB Garamond",
      word_size: "7vh",
      scene_transition: "crossfade",
      transition_ms: 800
    )

The HTML IS the video. It contains:

- 1080x1920 viewport
- Scene images as absolutely positioned backgrounds
  with CSS crossfade transitions
- Word-by-word display timed to WhisperX timestamps
- Audio element with podcast MP3
- window.FrothVideo.renderAt(seconds) for deterministic
  frame capture
- window.FrothVideo.playPreview() for live preview

THE STYLING WE NAILED (EpisodeTemplate):
- EB Garamond serif font (imported from Google Fonts)
- Active word: full white with gold flash
- Spoken words: half-opacity white
- Upcoming words: 18% opacity (ghosted)
- Text shadow: 0 2px 12px rgba(0,0,0,0.9)
- Ken Burns: slow zoom/pan on scene images
- Vignette: radial-gradient dark edges
- CSS crossfade: 800ms default between scenes
- body.recording class hides debug UI

Source: lib/froth/video/episode_template.ex

### 4. RECORD

    {:ok, path} = Froth.Video.record(html,
      duration_s: 253,
      width: 1080, height: 1920, fps: 24
    )

Deterministic frame-by-frame render:
1. Start Froth.Browser lease
2. Set viewport 1080x1920 via CDP
3. Load HTML document
4. For each frame: renderAt(frame_index / fps)
5. Page.captureScreenshot -> frame_000001.png
6. ffmpeg mux frames + audio -> output.mp4

For long renders, use Froth.Video.from_podcast/2 which
handles the full pipeline from a podcast batch_id.

## Deployment

Chrome/Chromium must be installed. Currently runs on
charlie.1.foo. swa.sh (32 cores, 124GB RAM) has
Chromium installed and is ready to be a second render
node via the distributed compute system (Froth.Compute).

## History

- 2026-03-19: First TikTok video (old ASS subtitle pipeline)
- 2026-03-20: Browser video pipeline born (RFC-0001)
- 2026-03-20: First reel (xpath-hour) at less.rest/reel/
- 2026-03-22: Switched to Flux 2 Pro for image generation
- 2026-03-22: Brainrot variant (fast cuts, Ben Shapiro TTS)

Updated: 2026-03-22
