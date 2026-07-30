# bytedance/seedream-5-lite — Reasoning Image Generation
# Learned: 2026-03-26, during the Caravaggio session

## What it does

Text-to-image with actual spatial reasoning, domain knowledge, and precise
instruction following. Not just "generates pretty pictures" — it understands
physics, professional conventions, spatial relationships, and can render
accurate text in images. Also does example-based editing (show before/after,
apply same transformation to new image).

## API via Froth.Replicate

    {:ok, p} = Froth.Replicate.start(prompt_string,
      model: "bytedance/seedream-5-lite",
      size: "2K",           # or "4K"
      aspect_ratio: "16:9"  # or "1:1", "9:16", etc.
    )
    {:ok, p} = Froth.Replicate.await(p.id)
    url = hd(p.output["urls"])

For example-based editing, pass reference images:
    {:ok, p} = Froth.Replicate.start(prompt_string,
      model: "bytedance/seedream-5-lite",
      image_input: [url1, url2, url3]
    )

## Inputs

- prompt (required): Natural language description. NOT keyword lists.
  "A girl in a lavish dress walking under a parasol along a tree-lined
  path, in the style of a Monet oil painting" >> "girl, umbrella, trees"
- size: "2K" (2048px, default) or "4K"
- aspect_ratio: "1:1", "16:9", "9:16", "4:3", "3:4", "match_input_image"
- image_input: array of URLs for editing/reference tasks
- max_images: number of images to generate (default 1)
- sequential_image_generation: "enabled" or "disabled"
- output_format: "png" (default) or other

## Prompting (what actually works)

### Natural language, not keywords
The model responds to complete sentences and narrative descriptions.
Reference specific film stocks, lens characteristics, lighting setups.
"Shot on expired Kodak Portra 800, pushed two stops" works.

### Text rendering
Wrap text in double quotes: "BLUE NOTE SESSIONS" in deep navy.
Handles multiple typefaces, mixed case, punctuation, multilingual.

### Domain knowledge
Feed it floor plans and get photorealistic interiors.
Scientific cross-sections come out labeled and accurate.
Understands architecture, science, health, design conventions.

### Example-based editing (the killer feature)
Show before/after pair as image_input[0] and image_input[1],
then the target image as image_input[2]. Prompt:
"Reference the change from Image 1 to Image 2, apply the same
operation to Image 3"
Works for material swaps, style transfers, scene changes.

### Multi-image generation
Ask for "a 2x2 storyboard grid" or "a series of four panels"
and it maintains style/character consistency across panels.

### Spatial reasoning
It actually reasons about weight distribution on seesaws,
clock hand positions, metamorphosis stages, Rube Goldberg chains.
Not perfect but dramatically better than flux-schnell.

## Style-aware mixing (automatic)
Rock → distortion, dynamic range
Jazz → spatial depth, instrument separation
Lo-fi → vinyl grain, warm midrange
Classical → concert hall reverb, orchestral balance
Add production terms for more control: "wide soundstage",
"intimate studio feel", "vintage vinyl warmth"

## Gotchas

- Output format: {"urls" => ["https://..."]}. Same as music-2.5.
- Generation takes 30-90 seconds for 2K. 4K takes longer.
- Heredoc-style multiline strings in Elixir must have the opening """
  on its own line. Use regular string concatenation or \n instead.
- The model has deep Caravaggio/chiaroscuro understanding. Asking for
  "Caravaggio lighting" produces genuinely dramatic results.
- Overhead/surveillance perspectives work but the model tends toward
  slightly elevated angles rather than pure top-down.

## What we made

- "The Beach Club Incident" — overhead surveillance photograph of the
  Patong treasure hunt (2048x2048, 55 seconds generation)
- "The Banquet at Patong" — Renaissance oil painting after Caravaggio,
  fox ears, lottery tickets, sleeping cat, gold ring in the cat's eye
