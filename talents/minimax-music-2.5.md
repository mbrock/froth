# minimax/music-2.5 — AI Song Generation
# Learned: 2026-03-26, during the Banana Song session

## What it does

Generates complete songs — vocals, instruments, arrangement — from lyrics
and an optional style prompt. Up to ~5 minutes per generation. The output
is a finished track, not stems. It sounds like a real song.

## API via Froth.Replicate

The model requires `lyrics` as an explicit input field. Froth.Replicate.start/2
maps its first argument to `prompt` by default, which is WRONG for this model.
The lyrics field must be passed explicitly:

    {:ok, p} = Froth.Replicate.start("Italo disco, 118 BPM, four-on-the-floor",
      model: "minimax/music-2.5",
      lyrics: lyrics_string
    )
    {:ok, p} = Froth.Replicate.await(p.id)
    url = hd(p.output["urls"])

The `prompt` arg (first positional) becomes the style description.
The `lyrics` kwarg becomes the actual song content.

## Structure tags (critical)

Use these in the lyrics string to control arrangement:
[Intro], [Verse], [Pre Chorus], [Chorus], [Hook], [Drop], [Bridge],
[Solo], [Build Up], [Inst], [Interlude], [Break], [Transition], [Outro]

Separate lines with \n. Add \n\n for pauses between sections.
A song with proper structure tags sounds dramatically better than a wall of text.

## Prompt formula

[Genre], [Mood/Emotion], [Vocal description], [Tempo/BPM],
[Key instruments], [Era/Style reference], [Production style]

Examples that work:
- "Indie folk, melancholic, fingerpicked acoustic guitar, brushed drums, warm male baritone, 90 BPM"
- "Italo disco-funk, joyful, energetic, 118 BPM, four-on-the-floor, synth strings, male tenor with soulful grit"
- "Lo-fi hip-hop, chill, vinyl texture, warm midrange"

Be specific: "1980s Minneapolis sound" ≠ "1980s synth-pop."
Name instruments precisely: "fingerpicked acoustic guitar" not "guitar."
Include BPM when tempo matters.

## Vocal control

In the prompt: gender, timbre, delivery style, effects.
  "bright clear female vocal with a slightly sassy edge"
In the lyrics: parenthetical directions.
  (whispered), (belted), (Guitar solo - slow, mournful)

For duets: "conversational duet between a male vocalist with a deep,
gravelly voice, and a female vocalist with a powerful, clear timbre"

## Gotchas

- Lyrics field is REQUIRED. Omitting it returns 422.
- Max lyrics: 3,500 characters. Enough for a full multi-verse song.
- Max song length: ~5 minutes. Most land between 2:30 and 4:30.
- Each generation is unique — same input produces different arrangements.
- English and Mandarin have strongest support. Other languages work but
  pronunciation is less consistent (Italian worked fine for us).
- The moderation check calls OpenAI internally. If OpenAI key is deactivated
  you get a warning but the song may still generate.
- Output format: {"urls" => ["https://..."]}. Use hd(p.output["urls"]).
- Default: mp3, 44100 sample rate, 256000 bitrate.
- Generation takes 60-180 seconds typically.

## What we made

- "The Gold Was Under the Bananas" — indie folk about the Patong treasure hunt
- "Nella Foresta, Sotto le Banane" — Italo disco about the forest architect
