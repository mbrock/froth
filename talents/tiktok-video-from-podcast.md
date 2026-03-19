# TikTok Video from Podcast

Generate a TikTok-style vertical video with word-by-word
subtitles from a podcast audio file, using AI-generated
portrait artwork as scene backgrounds.

## Pipeline

1. WHISPERX TRANSCRIPTION
   - Model: victor-upmeet/whisperx on Replicate
   - Input: podcast MP3 (must be publicly accessible URL)
   - Output: word-level timestamps with alignment
   - Key params: align_output=true, language="en"

2. BACKGROUND IMAGE GENERATION
   - Model: black-forest-labs/flux-1.1-pro on Replicate
   - Aspect ratio: 9:16 (portrait/vertical)
   - Generate 6-10 scene images based on podcast themes
   - Each scene covers a time range in the audio

3. ASS SUBTITLE GENERATION
   - PlayRes: 1080x1920 (portrait)
   - Font: JetBrains Mono, size 90
   - Two layers: main word (white + black outline)
     and glow layer (cyan/orange outline, no shadow)
   - Alignment: 5 (center of screen)
   - Each word appears alone, timed to WhisperX output

4. VIDEO ASSEMBLY (ffmpeg)
   - Image sequence via concat demuxer with durations
   - Scale + pad to 1080x1920
   - Burn ASS subtitles with -vf ass= filter
   - H.264 CRF 23, AAC 192k
   - -shortest to match audio duration

## Example ffmpeg command

    ffmpeg -y \
      -f concat -safe 0 -i concat.txt \
      -i podcast.mp3 \
      -vf "scale=1080:1920:force_original_aspect_ratio=decrease,\
           pad=1080:1920:(ow-iw)/2:(oh-ih)/2:black,\
           ass=subs.ass" \
      -c:v libx264 -preset fast -crf 23 \
      -pix_fmt yuv420p \
      -c:a aac -b:a 192k \
      -shortest \
      output.mp4

## concat.txt format

    file '/path/to/scene1.jpg'
    duration 45
    file '/path/to/scene2.jpg'
    duration 32
    ...
    file '/path/to/last_scene.jpg'

## ASS style definition

    Style: Word,JetBrains Mono,90,
      &H00FFFFFF,&H000000FF,&H00000000,&H80000000,
      -1,0,0,0,100,100,0,0,1,4,2,5,40,40,100,1

## Scene planning

Map podcast content to themes. Each theme gets one
Flux-generated portrait artwork. Scene transitions
happen on natural topic boundaries in the audio.

## First production

Podcast: GNU Bash LIVE mar19am9 "The Proprietary Blend"
Duration: 4:13
Scenes: 8 (chalk cliffs, goron/zelda, lojban rock,
  opus chronicle, garden state, voice clone,
  braff blend, loops)
Words: 635 with timestamps
Output: 15.3MB MP4, 1080x1920

Created: 2026-03-19

## IMPORTANT: Two-pass rendering

The concat demuxer with static images produces ~1 frame
per scene. The ASS filter needs actual frames at 24fps
to render word-by-word timing. Use two passes:

1. Generate a 24fps slideshow video first:
   For each scene, use -loop 1 on the image with
   -r 24 and -t duration to create a real video segment.
   Then concat the segments with -c copy.

2. Overlay ASS on the slideshow + audio:
   ffmpeg -y -i slideshow.mp4 -i podcast.mp3 \
     -vf "ass=subs.ass" \
     -c:v libx264 -preset fast -crf 23 \
     -c:a aac -b:a 192k -shortest output.mp4

## Font dependency

The ASS filter requires the font to be installed in
the system font cache. JetBrains Mono must be in
~/.local/share/fonts/ and fc-cache must be refreshed.
libass does NOT error on missing fonts — it silently
renders empty glyphs. Always verify with pixel diff.

Updated: 2026-03-19
