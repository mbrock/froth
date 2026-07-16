# Comic generation

`Froth.Comic` turns chat messages into Comic Chat-inspired PNG strips. It is a
pure callable service module; it does not add a process to the supervision tree.

```elixir
messages = [
  %{sender: "Ada", text: "Hello! :)", timestamp: DateTime.utc_now()},
  %{sender: "Lin", text: "THIS IS GREAT!!!", emotion: :happy}
]

{:ok, png} = Froth.Comic.render(messages)
File.write!("/tmp/chat.png", png)
```

`Froth.Comic.layout/2` returns panel, character, balloon, and tail geometry.
`Froth.Comic.render_svg/2` returns an inspectable vector representation. Options
currently include `:width` (at least 480), `:columns` (one to three), and
`:asset_root`.

## What was retained from Microsoft Comic Chat

The v1.0 source under `/tmp/comic-chat` has a few surprises:

- `semantic.cpp` is mostly a special-case Ohio/SIGGRAPH joke. The real expert
  system is in `textpose.cpp`, with rule data in `chat.rc`.
- Emotion candidates are priority-ranked. The original rules recognize all
  caps and `!!!`, `LOL`/`ROTFL`, emoticons, greetings, and phrases that point
  toward the speaker or another participant. `Froth.Comic.Semantic` retains
  those cues and adds common Unicode emoji equivalents.
- `panel.cpp` starts a panel for actions, explicit breaks, repeated speakers,
  five balloons, or a balloon that cannot fit. It places speaking avatars
  across the lower field, estimates balloon area from text, and protects a
  route from each balloon to its speaker. Froth uses the same constraints with
  deterministic, pixel-based geometry and starts at four balloons for mobile
  readability.
- `balloon.cpp` implements Woodring normal, whisper, thought, action, and mini
  balloon classes. Froth renders rounded, dashed, cloud-tail, caption, and
  jagged shout variants.
- `backdrop.cpp` crops a source backdrop to the panel and can disable zoom.
  Froth deterministically cycles and cover-crops the three bundled backdrops.

## AVB assets

`avatario.cpp` documents the binary container. Its header and metadata are
little-endian records; simple-avatar body records contain foreground,
transparency, and aura offsets followed by emotion and anchor metadata. Each
art offset points directly at a normal `BM` bitmap stream. No Win32 or MFC code
is needed to extract it.

The checked-in runtime set contains five simple, Woodring-style characters
(`waf`, `glenda`, `pedagog`, `rainbow`, and `tux`), the three v1.0 backdrops,
and `comic.ttf`. Regenerate them from a Comic Chat checkout with:

```bash
mix froth.comic.assets /tmp/comic-chat
```

The extractor uses ImageMagick's `convert` because this host's libvips build
does not enable its legacy BMP or SVG loaders. PNG composition and resizing use
the existing Elixir `Image` dependency; ImageMagick rasterizes the vector
balloon/text layer. `convert` must therefore be available on hosts that render
comics. The original MIT license is retained in
`priv/comic_chat/LICENSE.microsoft-comic-chat`.
