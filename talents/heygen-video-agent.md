# heygen/video-agent — AI Video Production
# Learned: 2026-03-26, during the Beach Club Incident

## What it does

Turn a text prompt into a complete video with AI-generated script, avatar
presenter, voiceover, visuals, and editing. One prompt in, finished video out.
The avatar is a deepfake news anchor. It scripts the segment, selects visuals,
records voiceover, edits transitions, adds captions. Full production pipeline.

## API via Froth.Replicate

    {:ok, p} = Froth.Replicate.start("ignored",
      model: "heygen/video-agent",
      prompt: "A 45-second deadpan investigative news segment about...",
      duration_sec: 45,
      orientation: "portrait"
    )
    {:ok, p} = Froth.Replicate.await(p.id)
    # Output is a single URL string, not a map:
    video_url = p.output

## Inputs

- prompt (required): Describe the video. Be specific about topic, tone,
  audience, purpose. "A 45-second deadpan investigative news segment"
  works better than "make a video about a beach club."
- avatar_id (optional): Specific HeyGen avatar. Omit to let the agent pick.
- duration_sec (optional): Target length in seconds. Minimum 5.
- orientation (optional): "landscape" or "portrait". Omit to auto-select.

## What we learned

- The output is a single URL string (mp4), not a {"urls": [...]} map.
  This is different from most Replicate models.
- Processing takes 3-10 minutes. Much longer than image or audio models.
  Set up a poller or use subscribe_task.
- The prediction ID is NOT stored in our replicate_predictions table if
  created via raw API call instead of Froth.Replicate.start. Use the
  Replicate API directly to check status if the DB doesn't have it.
- The avatar delivers the script with visible mouth movement, stock footage
  cutaways, lower-third captions, and transitions. Portrait orientation
  looks good for TikTok/Reels/Stories.
- The prompt is the entire creative brief. The more specific you are about
  tone ("deadpan BBC investigative"), content ("a Swedish man in fox ears"),
  and structure ("interview witness accounts"), the better.
- The model handles absurdist content well. It delivered a straight-faced
  investigative report about the Patong treasure hunt as though it were
  real breaking news. The avatar does not know it is the punchline.
- Output was ~19 MB for a 45-second portrait video.

## What we made

- "The Beach Club Incident" — a deadpan investigative segment about a
  Swedish man in fox ears who turned a Patong beach club into Squid Games
  using lottery tickets and a gold ring hidden under bananas.
