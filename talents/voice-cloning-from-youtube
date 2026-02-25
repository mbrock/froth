# Voice Cloning from YouTube
# Learned: 2026-02-20, during the Gilmore Girls session

## Pipeline (working)

1. Find source video on YouTube
2. Run `Froth.Podcast.analyze_voices_youtube(url)` — sends full video to Gemini 3.1 Pro
   which watches it natively and returns timestamps for clean 5-15s segments per speaker
3. Download audio from Mac Mini (not Hetzner — YouTube blocks headless servers):
   `ssh mikaels-mac-mini-2 "yt-dlp -x --audio-format mp3 -o '/tmp/NAME.%(ext)s' 'URL'"`
   Then `scp mikaels-mac-mini-2:/tmp/NAME.mp3 /tmp/`
4. Cut segments with ffmpeg using Gemini's timestamps:
   `ffmpeg -y -i source.mp3 -af "aselect='between(t,S1,E1)+between(t,S2,E2)',asetpts=N/SR/TB" output.mp3`
5. Clone: `Froth.Podcast.clone_voice(path, [{start, end}], "Name", noise_reduction: true)`
   - segments arg uses {start_seconds, end_seconds} tuples
   - single segment needs to match the `when length(segments) == 1` clause
6. Voice stored in VoiceClone table, retrievable as `Froth.VoiceClone.voice_id("name")`

## Critical lessons

- Clone the CHARACTER, not the ACTRESS. Interview voice ≠ performance voice.
  Lauren Graham on a podcast = "middle-aged feminist filling dead air."
  Lorelai at Luke's counter = the actual voice people hear in their heads.
- Use show footage for fictional characters, not press tours or speeches.
- Don't feed raw uncut files to the cloner. Cut the clean segments first.
  The cloner learns timbre from whatever you give it, including audience applause.
- Gemini can watch YouTube videos natively via analyze_voices_youtube.
  Don't download, chop into MP3 chunks, and send those separately. That's insane.
- yt-dlp on Hetzner is permanently bricked (no real browser, cookies expire).
  The Mac Mini in Riga has a Chrome installation YouTube trusts. Use it.

## For duos (Gilmore Girls, etc.)

- The sound isn't two people talking. It's one organism with two mouths.
- Write the script in VOLLEYS, not complete sentences.
  Fragments that rhyme, words that bounce, sentences that never finish.
- TTS will deliver fragments if the script gives it fragments. The bottleneck is the writing.

## Files involved

- Froth.Podcast.clone_voice/4 — the cloning function
- Froth.Podcast.analyze_voices_youtube/1 — Gemini video analysis
- Froth.VoiceClone — Ecto schema, .voice_id/1 for lookup, .by_name/1 for search
- Voice samples hosted at song.less.rest via /home/mbrock/songpost/dist/
