# Music Video Pipeline

Generate a complete animated music video from a song with
storyboard images, AI-animated clips, synchronized karaoke
subtitles, and a post-production filter grade. The pipeline
is manifest-driven: a single scenes.json file describes the
entire video and every tool reads from it.

Proven on: "The Structure of the Ring" (ring theory love song),
April 2026. 37 scenes, 301 seconds, $46 total production cost.
Five hours from first test to three-stage lossless pipeline on
distributed hardware.

## Project Structure

Each video lives in its own directory under priv/static/art/:

    priv/static/art/the-structure-of-the-ring/
      scenes.json           # The manifest — everything flows from this
      song.mp3              # Source audio
      timing.json           # WhisperX word-level timestamps
      intro_a.png           # Storyboard images (one per scene)
      intro_a.mp4           # SEEDANCE animated clips (one per scene)
      subtitles_ghost.ass   # Generated ASS subtitle file
      build_animated.py     # Concat animated clips into raw video
      build_ghost_subs.py   # Generate ghost-word ASS subtitles
      encode_pipeline.py    # Three-stage encode pipeline
      animated_no_audio.mp4 # Clean concat (no subs, no audio)

## The Manifest: scenes.json

The manifest is the single source of truth. Every tool reads it.

Top-level fields:
  - title: video title
  - style_prompt: base style for all image generation
  - inverted_style_prompt: style for "inversion" scenes
  - image_model: Replicate model for storyboard images (e.g. "black-forest-labs/flux-2-pro")
  - image_aspect_ratio: aspect ratio for images (e.g. "9:16")
  - video_model: Replicate model for animation (e.g. "bytedance/seedance-2.0")
  - video_aspect_ratio: aspect ratio for video (e.g. "9:16")
  - scenes: array of scene objects
  - continuous_lines: array matching scenes 1:1 with extended durations
  - lines: array of lyric lines with word-level timing from WhisperX

Scene object:
  - id: unique scene identifier (e.g. "v1_line2", "chorus_a", "solo_3")
  - start: scene start time in seconds (matches continuous_lines, not raw lyric)
  - end: scene end time in seconds
  - section: structural section (intro, verse, chorus, bridge, solo, outro)
  - lyric: the lyric text for this scene (empty for instrumental sections)
  - image_prompt: natural language prompt for storyboard image
  - video_prompt: natural language prompt for animation
  - display: optional array of display lines for subtitle splitting
    e.g. ["she taught me ideals", "in Budapest summer"]

continuous_lines vs scenes: scenes.start/end now match
continuous_lines after the April 12 patch. They partition
the entire song duration with no gaps. Previously, scene
start/end tracked raw lyric boundaries and continuous_lines
extended them to fill gaps — this caused SEEDANCE clips to
be generated at the wrong (shorter) durations. The fix was
to make scene start/end = continuous_lines start/end so
the Storyboard module requests correct-duration clips.

lines: word-level timing from WhisperX. Each line has
text, start, end, and a words array with per-word
start/end timestamps. Used by the subtitle generator.

## Pipeline Steps

### 1. COMPOSE SONG → Suno v5.5 or MiniMax Music 2.6

Write the song. This is the human creative step.
Suno v5.5 was used for "The Structure of the Ring."
MiniMax Music 2.6 is available via Froth.Replicate.

### 2. TRANSCRIBE → WhisperX

WhisperX does forced alignment — even when it mishears
words, the acoustic word boundaries are precise.

```elixir
{:ok, p} = Froth.Replicate.start("placeholder",
  model: "victor-upmeet/whisperx",
  audio_file: "https://less.rest/froth/art/project/song.mp3",
  align_output: true,
  language: "en",
  batch_size: 8
)
{:ok, p} = Froth.Replicate.await(p.id, 600_000)
```

Save output to timing.json. Extract word-level timestamps,
then correct the (often garbled) text with the real lyrics.
The timing is gold even when the words are wrong.

DO NOT USE regular Whisper for sung vocals. It hallucinates
entire sentences and collapses timestamps on held notes.

### 3. BUILD MANIFEST → scenes.json

Design the storyboard: decide how many scenes, where the
cuts fall, what each scene depicts. Write image_prompt and
video_prompt for each scene. Add display arrays for subtitle
line splitting at natural phrase boundaries.

Key constraint: SEEDANCE 2.0 generates clips up to ~15
seconds. Scenes longer than 15 seconds must be split.
The intro, choruses, solos, bridges, and outro should be
split into sub-scenes (intro_a, intro_b, ...) with distinct
visual prompts for variety.

Ensure scene start/end values partition the full song
duration with no gaps. Sum of all (end - start) must
equal the song duration from ffprobe.

### 4. STORYBOARD IMAGES → Flux 2 Pro

```elixir
Froth.Replicate.Storyboard.generate_images(
  "~/froth/priv/static/art/project/scenes.json"
)
```

Reads scenes.json, fires one Flux 2 Pro prediction per
scene in parallel (default concurrency 8), downloads
results as PNG files named by scene ID. ~5-10 seconds
per image. The style_prompt from the manifest is prepended
to each scene's image_prompt.

Flux 2 Pro dominates for geometric/abstract styles.
GPT Image 1.5 is better for illustrated crosshatch.
Choose based on the aesthetic.

### 5. ANIMATE → SEEDANCE 2.0

```elixir
Froth.Replicate.Storyboard.generate_videos(
  "~/froth/priv/static/art/project/scenes.json"
)
```

Reads scenes.json, uploads each scene's storyboard image
and audio clip to less.rest for public URL access, fires
one SEEDANCE 2.0 prediction per scene (default concurrency
4, max ~6 before Replicate queues), downloads results as
MP4 files. ~3 minutes per clip at standard quality.

SEEDANCE 2.0 Fast is available at bytedance/seedance-2.0-fast:
about 2x faster, 33% cheaper, slightly lower quality. Good
for drafting. Switch to standard for the final cut.

The Storyboard module reads duration from scene start/end,
so those MUST match the extended continuous_lines durations,
not the raw lyric durations. Otherwise clips are generated
too short and freeze-frame during playback.

SEEDANCE clips arrive at 720p 24fps. The encode pipeline
handles upscaling and frame interpolation.

### 6. CONCAT → build_animated.py

```bash
cd priv/static/art/project
python3 build_animated.py
```

Trims each SEEDANCE clip to exact scene duration, upscales
to 1080x1920, concatenates with hard cuts (no crossfade —
cleaner for geometric content, eliminates xfade timing bugs),
burns subtitles, muxes audio. Outputs animated_no_audio.mp4
(the clean concat) and the-structure-of-the-ring-animated.mp4
(with subs and audio).

For the three-stage pipeline, only animated_no_audio.mp4
matters — it's the clean source for all subsequent processing.

### 7. SUBTITLES → build_ghost_subs.py

```bash
cd priv/static/art/project
python3 build_ghost_subs.py
```

Generates ghost-word ASS subtitles from scenes.json:
  - Font: Equity A Caps (real small caps — install the OTF)
  - Size: 62pt, no outline (BorderStyle 1, Outline 0)
  - All text fully lowercased (the font renders as small caps)
  - Karaoke reveal: \k per word, unrevealed words invisible
    (SecondaryColour alpha FF), revealed words full white
  - Zero linger: line disappears the instant the last word
    ends. The lagfun phosphor trail in the encode pipeline
    handles the visual fade-out — 25 frames (~400ms at 60fps)
    of neon ghost. Having both ASS linger and lagfun trail
    produces double-fading.
  - No commas in subtitle text
  - Display splits from the display[] array in scenes.json
    for natural phrase boundaries

Output: subtitles_ghost.ass

### 8. ENCODE → encode_pipeline.py (THREE STAGES)

The encode pipeline runs on swa.sh (Ryzen 9 7950X3D, 32
threads, 124GB RAM) for speed. Deploy files with rsync:

```bash
rsync -avP animated_no_audio.mp4 song.mp3 subtitles_ghost.ass \
  encode_pipeline.py swa.sh:/tmp/ring/
# Also install Equity A Caps fonts on swa:
rsync -avP ~/.local/share/fonts/Equity\ A\ Caps*.otf swa.sh:/tmp/ring/
ssh swa.sh "mkdir -p ~/.local/share/fonts && cp /tmp/ring/*.otf \
  ~/.local/share/fonts/ && fc-cache -f"
```

Stage 1: BASE (re-run only when clips or gradient change)
```bash
ssh swa.sh "cd /tmp/ring && python3 encode_pipeline.py --stage base"
```
  gradient overlay → 60fps blend interpolation → FFV1 lossless
  The gradient darkens the bottom 20% of the frame (where
  subtitles sit) from transparent to black over 400 pixels.
  Blend interpolation (mi_mode=blend) doubles/triples the
  framerate by alpha-blending adjacent frames — dreamy,
  double-exposure quality. ~2.5 minutes on swa.
  Output: staged_base.mkv (~11GB FFV1 lossless)

Stage 2: SUBS (re-run when subtitle text/timing/font changes)
```bash
ssh swa.sh "cd /tmp/ring && python3 encode_pipeline.py --stage subs"
```
  Burns ASS subtitles onto lossless base. Single filter pass.
  ~1.5 minutes on swa.
  Output: staged_subbed.mkv (~11GB FFV1 lossless)

Stage 3: GRADE (re-run freely to iterate on the aesthetic)
```bash
ssh swa.sh "cd /tmp/ring && python3 encode_pipeline.py --stage grade"
ssh swa.sh "cd /tmp/ring && python3 encode_pipeline.py --stage grade \
  --bloom 0.12 --decay 0.96 --grain 6 \
  --curves '0/0 0.25/0.1 0.5/0.3 1/1'"
```
  The filter stack, in order:
  - lagfun: phosphor decay trails (decay=0.96, ~25 frame ghost)
    Bright pixels fade out slowly, leaving neon afterimages.
    On wireframe geometry this produces light-sculpture trails.
  - bloom: gaussian blur (sigma=25) blended back at 12% screen
    opacity. Bright geometry bleeds light into the void.
  - curves: midtone crush toward black. Keeps highlights bright
    but makes the bloom haze thin and dark instead of foggy.
    '0/0 0.25/0.1 0.5/0.3 1/1' — the void gets blacker.
  - grain: temporal film noise (strength 6). Breaks up digital
    perfection, makes the void feel inhabited.
  - fade: 3-second fade to black at the end.
  ~3-4 minutes on swa.
  Output: the-structure-of-the-ring-final.mp4 (H.264 CRF 20)

Pull the result back:
```bash
rsync -avP swa.sh:/tmp/ring/the-structure-of-the-ring-final.mp4 .
```

### 9. SEND TO TELEGRAM

```elixir
Froth.Telegram.send_video("charlie", chat_id, path,
  caption: "Title — description",
  width: 1080, height: 1920
)
```

Always pass width/height explicitly. TDLib caches wrong
dimensions from partial reads. Use a unique file path for
each upload to avoid stale cache hits.

Telegram has a ~2GB upload limit via TDLib (not the 50MB
Bot API limit). Our 331MB final was fine.

## Filter Stack Reference

These ffmpeg filters are the ones that matter for this aesthetic:

lagfun: phosphor decay. decay=0.95 subtle, 0.96 medium, 0.99 heavy smear.
  Each pixel fades out at decay^frames_since_bright. Simulates CRT phosphor.

gblur + screen blend: bloom/glow. sigma controls spread (25=wide halo,
  10=tight corona). Opacity controls intensity (0.1=subtle, 0.3=fog).

curves: tone mapping. master='0/0 0.3/0.15 0.7/0.5 1/1' darkens mids.
  Use to crush the bloom haze without losing highlights.

noise: film grain. c0s=6 subtle, c0s=12 heavy. c0f=t for temporal
  (changes per frame like real film stock).

minterpolate: frame interpolation.
  mi_mode=blend: alpha-blend between frames. 35x faster than MCI.
    Dreamy, double-exposure quality. Good for geometric content.
  mi_mode=mci: motion-compensated interpolation. Sharp, cinematic.
    Good quality but slow. Best run per-clip in parallel.

chromashift: RGB channel offset. Instant chromatic aberration.
colortemperature: warm/cool shift (4500=tungsten, 8000=cold).
vignette: darken edges.
tmix: average N consecutive frames. Memory effect.

## Blend-First vs Blend-Last

Blend-first (interpolate to 60fps THEN apply lagfun/bloom):
  The lagfun sees 60fps input — positions 17ms apart — so trails
  flow continuously. The bloom breathes more smoothly. The grain
  is per-frame at 60fps, like actual film stock. Better quality.
  ~2.5x more frames through the heavy filters. Worth it.

Blend-last (apply effects at 24fps THEN interpolate):
  The lagfun steps between 42ms positions, then blend smooths
  the result. Trails strobe slightly. Faster but lower quality.

The three-stage pipeline uses blend-first in stage 1.

## Remote Encoding on swa.sh

swa.sh is on the Elixir cluster (node :froth@swa) and reachable
via ssh swa.sh as mbrock. No user needed in the ssh command.

  igloo: 20 threads, i5-13500, 62GB RAM
  swa.sh: 32 threads, Ryzen 9 7950X3D (3D V-Cache), 124GB RAM
  Mikaels-Mac-mini-2: also on cluster, ssh Mikaels-Mac-mini-2

swa is roughly 2x faster for encoding workloads. The V-Cache
helps with the random-access patterns that lagfun and
minterpolate produce.

ffmpeg is installed on swa.sh (6.1.1 via apt, installed April 12).
Equity A Caps fonts must be installed manually (rsync OTF files
to ~/.local/share/fonts/ and run fc-cache -f).

## Designed but Not Yet Built: Per-Clip Distributed Pipeline

The current pipeline processes the entire 301-second video as
a single stream. The lagfun state bleeds across hard cuts, and
the serial filter chain can't fully utilize swa's 32 threads.

The next architecture: process each of the 37 clips independently.

  Stage 0 (new): distribute raw SEEDANCE clips across
    swa/igloo/mac-mini. MCI each to 60fps independently.
    37 parallel jobs, each 5-12 seconds, ~90 seconds total
    wall clock across three machines.

  Per-clip grade: lagfun with fresh state per clip (no cross-
    cut bleeding), bloom, curves, grain, and a fade-through-
    black envelope at both boundaries (6 frames = 100ms at
    60fps). The envelope hides freeze-frame glitches at clip
    tails and creates clean visual breaths between scenes.

  Concat: demuxer join of pre-graded clips. No re-encoding.
    Then a single lightweight pass for subtitle burn + audio mux.

Benefits:
  - Embarrassingly parallel: 37 independent jobs across N machines
  - Per-clip MCI: sharp interpolation without cross-cut artifacts
  - Lagfun reset: phosphor trails don't bleed across scene cuts
  - Fade envelope: hides clip boundary glitches
  - Grade iteration: change a parameter, re-run 37 jobs in 90 seconds

## Lessons Learned

1. WhisperX for music, not regular Whisper. Forced alignment
   gives precise word boundaries even on garbled transcriptions.

2. Flux 2 Pro for geometric/abstract. GPT Image 1.5 for illustrated.

3. Scene durations must partition the full song. Gaps between
   lyric lines must be allocated to scenes, not left as dead time.
   The continuous_lines array in scenes.json does this.

4. SEEDANCE clips must be requested at the extended duration,
   not the raw lyric duration. Otherwise freeze-frame padding.

5. Hard cuts > crossfade for geometric content. Crossfade
   produces PowerPoint dissolves. Hard cuts are honest about
   scene changes and eliminate xfade timing bugs.

6. Blend interpolation is 35x faster than MCI with nearly
   identical visual quality for slow-motion geometric content.
   Use blend for drafting, MCI for final per-clip processing.

7. ASS subtitles cannot do per-word independent alpha transitions.
   The ghost-word effect is a compromise using \k karaoke reveal
   with invisible SecondaryColour. True per-glyph animation
   requires the browser renderer (Canvas/WebGL).

8. Lagfun handles subtitle fade-out. Set ASS linger to zero
   and let the phosphor trail carry the text ghost. Double-
   fading (ASS linger + lagfun) looks mushy.

9. Lossless intermediates (FFV1) between encode stages. The
   quality difference from re-encoding lossy H.264 through
   the filter chain is visible on geometric content.

10. The three-stage pipeline saves iteration time: stage 1
    (base) runs once, stage 2 (subs) runs on text changes,
    stage 3 (grade) runs on aesthetic changes. Only the
    changed stage needs re-encoding.

11. swa.sh is ~2x faster than igloo for ffmpeg encoding but
    only uses ~33% of its cores because the filter chain is
    serial. The per-clip distributed architecture would
    unlock the full machine.

12. Always pass width:1080, height:1920 when uploading to
    Telegram via TDLib. It caches wrong dimensions.
