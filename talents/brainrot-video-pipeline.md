# Brainrot Video Pipeline

Generate a TikTok-style brainrot video from a text
transcript. AI voice, AI images, word-by-word gold
highlighting, fast cuts.

## Pipeline

1. SCRIPT → TTS (Froth.Podcast.generate)
   - Input: text broken into segments
   - Voice: any cloned voice from voice_clones table
   - Model: minimax/speech-2.8-hd on Replicate
   - Output: stitched MP3 at /tmp/podcast_{batch_id}_final.mp3
   - Also saved to priv/static/audio/hourly/{batch_id}.mp3
   - Publicly accessible at less.rest/froth/audio/hourly/{batch_id}.mp3

   Example:
       script = [
         {:ben_shapiro, "A man in Thailand turned himself into cement."},
         {:ben_shapiro, "His eyes cemented shut in the shower."}
       ]
       {:ok, batch_id} = Froth.Podcast.generate(script,
         chat_id: chat_id,
         label: "Cementmaxxing Brainrot",
         pause_ms: 200,
         language: "English",
         concurrency: 4
       )

2. WHISPERX TRANSCRIPTION (Froth.Video.transcribe)
   - Input: public MP3 URL
   - Model: vaibhavs10/incredibly-fast-whisper on Replicate (29M runs, always warm)
   - AVOID: victor-upmeet/whisperx (cold start downloads 360MB model)
   - Output: word-level timestamps
   - Returns [{word, start, end}, ...]
   - REQUIRED for the compose step (word-by-word highlighting)

   Example:
       audio_url = "https://less.rest/froth/audio/hourly/#{batch_id}.mp3"
       {:ok, words} = Froth.Video.transcribe(audio_url)

3. IMAGE GENERATION (Froth.Replicate.start)
   - Model: black-forest-labs/flux-2-pro (as of 2026-03-22)
   - Aspect ratio: 9:16 (portrait)
   - safety_tolerance: 5
   - Generate 8-12 images based on transcript themes
   - Fire all in parallel, await with Froth.Replicate.await/2

   Example:
       {:ok, p} = Froth.Replicate.start(prompt,
         model: "black-forest-labs/flux-2-pro",
         aspect_ratio: "9:16",
         safety_tolerance: 5
       )
       {:ok, p} = Froth.Replicate.await(p.id, 120_000)
       url = hd(p.output["urls"])

4. COMPOSE (Froth.Video.compose)
   - Input: words + scene URLs + audio URL + opts
   - Output: self-contained HTML string
   - THE IMPORTANT PART: this produces the HTML with
     EB Garamond serif font, word-by-word gold highlighting
     (active word goes bright, spoken words at half-opacity,
     upcoming at 18% opacity), Ken Burns drift on scenes,
     vignette gradient, CSS crossfade transitions
   - Exposes window.FrothVideo.renderAt(t) for deterministic
     frame capture

   Example:
       scenes = Enum.map(image_urls, fn url ->
         %{url: url, duration_s: duration / num_images}
       end)
       html = Froth.Video.compose(words, scenes, audio_url,
         title: "CEMENTMAXXING",
         font: "EB Garamond",
         word_size: "7vh"
       )

5. RECORD (Froth.Video.record)
   - Input: HTML string + duration
   - Output: MP4 file path
   - Deterministic: calls renderAt(frame_time) per frame
   - 1080x1920, 24fps, H.264 CRF 23

   Example:
       {:ok, path} = Froth.Video.record(html,
         duration_s: 87,
         width: 1080, height: 1920, fps: 24
       )

6. SEND TO CHAT (Froth.Telegram.send_video)
   - Upload final MP4 to Telegram

## Voice Clones Available (as of 2026-03-22)

Check with:
    Froth.Repo.all(from vc in "voice_clones",
      select: %{name: vc.name, voice_id: vc.voice_id})

Known: Ben Shapiro (R8_4ZCEOW56), Trump (R8_9W34M852),
Alex Schulman, Sigge Eklund, Thorsten Flinck, Kungen,
Jocke, and others.

## Key Styling (THE THING WE NAILED)

The EpisodeTemplate (lib/froth/video/episode_template.ex)
produces HTML with:
- EB Garamond or Cormorant Garamond serif
- Words at 18% opacity (upcoming), rising to full white
  (spoken), with gold flash on active word
- Ken Burns slow zoom/pan on scene images
- Vignette: radial gradient dark edges
- CSS crossfade between scenes (800ms default)
- 1080x1920 viewport (portrait/vertical)
- Debug overlay hidden in recording mode

This is the house style. Do not rebuild it from scratch.
Use Froth.Video.compose which calls EpisodeTemplate.render.

## Brainrot Tone Guidelines

The brainrot format uses:
- ALL CAPS delivery in the TTS script
- Fast cuts (3-5 seconds per scene, not 7+)
- Hyperbolic escalation ("SCIENTISTS CALL THIS CONCRETE.
  HE CALLED IT BREAKFAST.")
- The subway surfers / minecraft parkour subtitle note
  at the end (for the meme)

Created: 2026-03-22
Updated: 2026-03-22
