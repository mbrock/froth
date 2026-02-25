# Froth

Froth is a thinking interface. It accepts text and returns text. It runs at
`less.rest/froth`.

## What it is

Two things live under one roof:

1. **Charlie** — a Telegram bot (`@charliebuddybot`) that responds to mentions
   in a group chat. Charlie has a persistent tool loop: the LLM can call
   `send_message`, `read_log`, `search`, `view_analysis`, and `elixir_eval`.
   Non-`elixir_eval` tools run automatically; `elixir_eval` can be controlled
   from the Telegram Mini App. Conversation state is persisted in Postgres so
   it survives restarts. Charlie also has a Telegram Mini App where
   `elixir_eval` tool output streams in real time.

2. **Media analyzers** — Oban workers that process Telegram messages with
   photos, voice notes, videos, YouTube links, X/Twitter posts, and PDFs. Each
   media type has its own worker and its own LLM backend. Results go into the
   `analyses` table.

## Stack

- Elixir / Phoenix 1.8.3 / LiveView 1.1.0 / Bandit
- Tailwind 4, daisyUI
- Postgres via Ecto
- Oban for background jobs
- Finch for all HTTP (Anthropic SSE, Replicate, Gemini, Grok)
- TDLib via Erlang C node for Telegram

## Supervision tree

`Froth.Application` starts these children in order:

- `FrothWeb.Telemetry`
- `Froth.Repo` — Ecto/Postgres
- `Oban` — background job queue
- `Finch` (as `Froth.Finch`) — HTTP connection pool
- `Froth.Dataset` — in-memory RDF dataset (auto-loads from `datasets` DB table)
- `Phoenix.PubSub` (as `Froth.PubSub`)
- `Froth.Telegram` — supervisor for TDLib sessions (Registry + Cnode + DynamicSupervisor)
- `Froth.Telegram.Bots` — bot runtimes
- `Task.Supervisor` (as `Froth.TaskSupervisor`)
- `FrothWeb.Endpoint`

Sends `sd_notify READY=1` after startup for systemd integration.

## Routes

```
GET  /froth                   AnalysesLive    — browse media analyses by day
GET  /froth/analyses          AnalysesLive
GET  /froth/analyses/:day     AnalysesLive
GET  /froth/dataset           DatasetLive     — RDF dataset browser
GET  /froth/rdf               RdfLive         — RDF browser
GET  /froth/media/:chat_id/:message_id  MediaController — serve Telegram media

GET  /froth/mini/app          ToolLive        — Telegram Mini App landing
GET  /froth/mini/tool/:ref    ToolLive        — tool execution viewer
POST /froth/mini/debug        MiniDebugController
```

## LLM integration (`Froth.Anthropic`)

Two calling patterns:

- `reply/1` — synchronous, takes `[%{role: :user, text: "..."}]`, returns `{:ok, text}`
- `stream_reply_with_tools/3` — streaming with automatic tool loop. Fires events:
  `{:text_delta, text}`, `{:thinking_start, info}`, `{:thinking_delta, delta}`,
  `{:thinking_stop, info}`, `{:tool_use_start, tool}`, `{:tool_use_delta, delta}`,
  `{:tool_use_stop, tool}`, `{:tool_result, result}`

There's also `stream_single/3` which does one streaming call without tool looping
(used by Charlie).

Config from env vars: `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL` (default
`claude-opus-4-6`), `ANTHROPIC_MAX_TOKENS` (default `16384`),
`ANTHROPIC_THINKING` (default `enabled`),
`ANTHROPIC_THINKING_BUDGET_TOKENS` (default `1024`), `ANTHROPIC_EFFORT`.
Also checks `api_keys` DB table for active Anthropic keys.

Opus 4.6 gets adaptive thinking by default.

SSE parsing lives in `Froth.Anthropic.SSE`.

## Tools (`Froth.Tools`, `Froth.Inference.Tools`)

`elixir_eval` executes Elixir code on the live node with a timeout and can
broadcast streamed IO output over PubSub (`run_eval_broadcast`) for the Mini
App real-time viewer.

Telegram inference sessions expose tools including `send_message`, `read_log`,
`search`, `view_analysis`, and `elixir_eval`.

## Telegram (`Froth.Telegram`)

Multi-session TDLib bridge. Architecture:

- `Froth.Telegram` — supervisor, starts Registry + Cnode + DynamicSupervisor
- `Froth.Telegram.Cnode` — manages the shared C node process (`cnode/tdlib_cnode`)
- `Froth.Telegram.Session` — per-session GenServer, registered in Registry
- `Froth.Telegram.Sync` — captures `updateNewMessage` events to `telegram_messages` table
- `Froth.Telegram.SessionConfig` — Ecto schema, `telegram_sessions` DB table

Sessions are configured in the DB (`telegram_sessions` table, `enabled: true`
auto-starts). Two sessions exist:
- `"charlie"` — bot session (`@mrwalter_bot`, user ID `6789382533`)
- `"mbrockman"` — user account session

Key constraints:
- Bot accounts can't call `getChatHistory`/`getChats` — need user session for backfill
- TDLib file IDs are local to each session instance — always call `getMessage` for fresh IDs
- C node uses `prctl(PR_SET_PDEATHSIG, SIGTERM)` to prevent orphan processes

Messaging: `Froth.Telegram.send/2` (async), `Froth.Telegram.call/3` (sync).
Also `send_photo/4` and `send_video/4` which download HTTP URLs to temp files first.

### Calls (`tgcalls` + TDLib user sessions)

`vendor/tgcalls` is added as a submodule. It can be used for both private
calls and group/video calls, but should run on a user TDLib session (not bot).

Pinned dependency set (aligned to recent upstream Telegram app pins):

- `vendor/tgcalls` `24876ebca7da10f92dc972225734337f9e793054`
- `vendor/webrtc` `dfd6b604d7194a3d41614afa2c8abd8825a657aa`
- `vendor/chromium-base` `fd5eca261fa03e22f053a0eaa5b010ca01c6fe51`
- `vendor/chromium-build` `a3566ffdee8a4dda521d05c378d915427d049292`
- `vendor/abseil-cpp` `2812af9184eaa2bfd18d1545c57bcf8cbee88a9d`
- `vendor/libyuv` `2f2c04c1576534a7df953c2dc7c7ccf30beacd89`
- `vendor/ffmpeg` `7c1b0b524c639beeb25363b1d0809ebe5c6efe5e`
- `vendor/rnnoise` `70f1d256acd4b34a572f999a05c87bf00b67730d`

Basic compile check (no final link yet):

```bash
git submodule update --init --recursive
bin/build_tgcalls_smoke
```

Minimal C node integration check:

```elixir
Froth.Telegram.Cnode.tgcalls_status()
#=> {:ok,
#=>  %{
#=>    "linked" => true,
#=>    "engine_available" => false,
#=>    "registered_versions" => [],
#=>    "max_layer" => 0,
#=>    "registration_source" => "none",
#=>    "registration_attempted" => false,
#=>    "registration_ok" => false,
#=>    "plugin_path" => "",
#=>    "registration_error" => "set FROTH_TGCALLS_PLUGIN to a registration plugin"
#=>  }}
```

Runtime plugin bridge for real implementations:

```bash
# Build only when you already have implementation libs to link.
cmake -S cnode/tdlib_cnode -B cnode/tdlib_cnode/build_plugin \
  -DFROTH_TGCALLS_BUILD_REGISTER_PLUGIN=ON \
  -DFROTH_TGCALLS_PLUGIN_EXTRA_LIBS="/abs/path/libtgcalls_impl.a;/abs/path/libwebrtc.a"
cmake --build cnode/tdlib_cnode/build_plugin --target froth_tgcalls_register_plugin -j

# Then start BEAM/cnode with:
export FROTH_TGCALLS_PLUGIN=/abs/path/libfroth_tgcalls_register_plugin.so
```

Elixir call-control helpers:

```elixir
alias Froth.Telegram.Calls

protocol = Calls.call_protocol()
{:ok, call} = Calls.create_call("mbrockman", user_id, protocol: protocol)
_ = Calls.send_call_signaling_data("mbrockman", call["id"], raw_signaling_bytes)
_ = Calls.discard_call("mbrockman", call["id"])
```

Local media frame pump helpers:

```elixir
alias Froth.Telegram.Calls

call_id = call["id"]
:ok = Calls.start_private_media(call_id, self())
:ok = Calls.feed_pcm_file(call_id, "/tmp/clip.pcm")

receive do
  {:call_audio, ^call_id, pcm_frame} ->
    # PCM16LE mono 48k, ~20ms per frame
    IO.puts("got #{byte_size(pcm_frame)} bytes")
end
```

TDLib update bridge helpers (signaling + runtime startup):

```elixir
alias Froth.Telegram.Calls

Froth.Telegram.subscribe("mbrockman")

receive do
  {:telegram_update, update} ->
    # routes updateCall/updateNewCallSignalingData into cnode tgcalls bridge
    _ = Calls.route_tgcalls_update("mbrockman", update, pid: self())
end
```

Private call flow (1:1):

- Build a `callProtocol` from local `tgcalls` support:
  - `min_layer=65`, `max_layer=92`
  - `library_versions` intersection with local `tgcalls` versions
- Start or accept call through TDLib:
  - outgoing: `createCall`
  - incoming: `acceptCall`
- Wait for `updateCall` with `call.state=@type=callStateReady`.
- Create a `tgcalls::Instance` for a mutually supported version.
- Map TDLib `callStateReady.servers` into `tgcalls` RTC server descriptors.
- Bridge signaling both ways:
  - `tgcalls` `signalingDataEmitted` -> TDLib `sendCallSignalingData`
  - TDLib `updateNewCallSignalingData` -> `tgcalls` `receiveSignalingData`
- On hangup/disconnect, call TDLib `discardCall`.
- If `callStateDiscarded` requests it, send rating/debug/log via:
  `sendCallRating`, `sendCallDebugInformation`, `sendCallLog`.

Group/video call flow:

- Create `tgcalls` group instance (`GroupInstanceCustomImpl`).
- Ask `tgcalls` for local join data (`emitJoinPayload`) and audio source ID.
- Join in TDLib with:
  - `joinVideoChat` (chat-bound video chat)
  - `joinGroupCall` (standalone group call)
  - `joinLiveStory` (live story)
- Pass TDLib join response payload back to `tgcalls` via
  `setJoinResponsePayload`.
- Rejoin if TDLib reports `groupCall.need_rejoin`.
- Optionally drive participant media selection with
  `setRequestedVideoChannels` and participant updates from
  `updateGroupCallParticipant`.

Practical recommendation:

- Keep one dedicated user session for call control/media.
- Continue using bot sessions for chat automation; TDLib voice/video control is
  done via the user session.

## Charlie (`Froth.Telegram.Charlie`)

The bot GenServer. Listens on PubSub for the `"charlie"` session's updates.

Activation: responds when `@charliebuddybot` is mentioned, or when someone
replies to one of its messages. Only in chats where the owner (user
`362441422`) is a member.

Conversation lifecycle: `start_conversation` -> `start_streaming` -> LLM
returns tool uses -> `build_pending_tools` (`send_message` plus non-`elixir_eval`
tools auto-execute, `elixir_eval` is queued) -> `awaiting_tools` ->
`elixir_eval` executes -> results fed back -> loop.

State is persisted in `charlie_conversations` table (`Froth.Telegram.Conversation`
schema). Survives node restarts — on startup, interrupted conversations get
cleaned up, and conversations waiting on resolved tools auto-resume.

Context comes from `Froth.Summarizer.context/1` which builds XML with daily
summaries + recent raw messages with analysis snippets.

## Summarizer (`Froth.Summarizer`)

Generates narrative daily summaries of Telegram chat transcripts using Opus 4.6.
Stored in `chat_summaries` table. `context/1` builds the XML context document
that Charlie uses as grounding.

## Analyzers

Oban workers in `lib/froth/analyzer/`. Each watches for specific message types:

| Worker | Media type | LLM | Model |
|--------|-----------|-----|-------|
| `ImageWorker` | photos | Claude | claude-sonnet-4-5 |
| `VoiceWorker` | voice notes | Gemini | gemini-3-flash-preview |
| `VideoWorker` | videos | Gemini | gemini-3-flash-preview |
| `YouTubeWorker` | YouTube URLs | Gemini | gemini-3-flash-preview |
| `XPostWorker` | X/Twitter posts | Grok | grok-4-1-fast-non-reasoning |
| `PdfWorker` | PDFs | — | — |

`Froth.Analyzer.Discovery` finds unanalyzed messages and enqueues the right
worker. Results go to `analyses` table. `Froth.Analyzer.API` has HTTP clients
for Gemini, Grok, and Claude APIs.

All media workers call `getMessage` fresh from TDLib because stored file IDs
may be stale. Video worker waits for Gemini file upload to reach ACTIVE state.

Oban config: `max_attempts: 20`, pruner only cleans completed/cancelled jobs.

## Replicate (`Froth.Replicate`)

Client for the Replicate API (image/video generation). Oban-backed async
predictions with DB persistence.

```elixir
{:ok, p} = Froth.Replicate.run("a white cube")
url = hd(p.output["urls"])
Froth.Telegram.send_photo("charlie", chat_id, url, caption: "here")
```

Also syncs Replicate model collections and GitHub READMEs to Postgres
(`replicate_models`, `replicate_collections`, `replicate_predictions` tables).

## RDF Dataset (`Froth.Dataset`)

In-memory RDF dataset GenServer. Auto-loads from `datasets` DB table on startup.
Supports SPARQL queries and triple pattern matching via the `rdf` and `sparql`
Elixir libraries.

## Database tables

- `telegram_sessions` — TDLib session configs
- `telegram_messages` — synced Telegram messages (chat_id, message_id, sender_id, date, raw jsonb)
- `analyses` — media analysis results (type, chat_id, message_id, agent, analysis_text, metadata)
- `chat_summaries` — daily chat summaries
- `telegram_inference_sessions` — persistent tool-loop state (api_messages, status, tool_steps, queued_messages)
- `api_keys` — API key management (provider, key, active)
- `replicate_predictions` / `replicate_models` / `replicate_collections` — Replicate data
- `datasets` — stored RDF datasets
- `oban_jobs` / `oban_peers` — Oban internals

## Deployment

Runs as a systemd user service on `igloo`.

- `bin/serve` — start the server
- `bin/deploy` — build and deploy
- `bin/restart` — restart the service
- `bin/logs` — view logs (`-f` to follow, `--since "5 min ago"`)
- `bin/rpc` — run Elixir code on the live `froth@igloo` node
- `bin/build_tdlib_cnode` — compile the C node

Live node is `froth@igloo`. After `mix compile`, reload modules with:
```elixir
:code.purge(Module); :code.load_file(Module)
```
Warning: `:code.purge` kills processes running old code.

`bin/rpc` uses `Froth.RPC.eval/2` which sets group_leader for IO routing.
Use heredoc (`cat <<'EOF' | bin/rpc`) to avoid shell escaping issues.

## Design

Black background, white text, 13px base, tight spacing, no rounded corners,
no padding bloat. Compact and crisp. Not the default Claude aesthetic.
