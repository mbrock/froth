# Froth Route Audit

- Generated at: 2026-03-25 21:09:53 UTC
- Base URL: https://less.rest
- Captured: 48
- Skipped: 0
- Errors: 3

## 1. `GET /froth/objects/*key`

- URL: https://less.rest/froth/objects/agent/cycles/01KMEDA61398D5XPB78W9MZPA0/events/control-outcome-30532.json
- Screenshot: `screenshots/001-froth-objects-agent-cycles-01kmeda61398d5xpb78w9mzpa0-events-control-outcome-30532-json.png`
- Description: Controller FrothWeb.ObjectStoreController#show. Preview: {"error":"{{:badkey, :span_id, %{started_at: -576434574061605074, task: %Task{mfa: {:erlang, :apply, 2}, owner: #PID<0.4423.0>, pid: #PID<0.6513.0>, ref: #Reference<0.0.566147.2205590515.4261216258.113156>}, ref: #Reference<0.0.566147.2205590515.4261216258.113156>, timer_ref: #Re
- Sample Source: first object-store key

## 2. `GET /froth/summaries`

- URL: https://less.rest/froth/summaries
- Screenshot: `screenshots/002-froth-summaries.png`
- Title: The Chronicle — Daily Summaries from CRIME SCENE
- Heading: The Chronicle
- Description: Controller FrothWeb.SummariesController#index. Shows The Chronicle. Preview: The Chronicle Daily summaries from CRIME SCENE A group chat between two brothers and their fictional children Tuesday, March 24, 2026 2010 messages March 24th, 2026, was the day Charlie test-drove GPT-5.4-mini and discovered it thinks with reasoning tokens only when tools are inv
- Sample Source: static route

## 3. `GET /froth/headlines`

- URL: https://less.rest/froth/headlines
- Screenshot: `screenshots/003-froth-headlines.png`
- Title: Headlines
- Heading: HEADLINES
- Description: LiveView FrothWeb.HeadlinesLive#index. Shows HEADLINES. Preview: FROTH / SAVED REGISTER HEADLINES A CONCRETE SLAB OF EVERY FILED TABLOID HEADLINE, PULLED STRAIGHT FROM THE EVENT LOG. COVERAGE 49 / 49 DAYS FILED HEADLINES 144 SAVED TOTAL MISSING 0 UNFILED DAYS ACTIVE CHAT -1003690254489 CHAT SWITCHBOARD -1003690254489 MONTH INDEX MARCH 2026 23
- Sample Source: static route

## 4. `GET /froth`

- URL: https://less.rest/froth
- Screenshot: `screenshots/004-froth.png`
- Title: Froth
- Heading: Wednesday, March 25
- Description: LiveView FrothWeb.AnalysesLive#index. Shows Wednesday, March 25. Preview: ← Wednesday, March 25 → inference dataset rdf 58 analyses Mar 25 Mar 24 Mar 23 Mar 22 Mar 21 Mar 20 Mar 19 Mar 18 Mar 17 Mar 16 Mar 15 Mar 14 Mar 13 Mar 12 Mar 11 Mar 10 Mar 09 Mar 08 Mar 07 Mar 03 Mar 02 Mar 01 Feb 28 Feb 27 Feb 26 Feb 25 Feb 24 Feb 23 Feb 22 Feb 21 Feb 20 Feb 1
- Sample Source: static route

## 5. `GET /froth/analyses`

- URL: https://less.rest/froth/analyses
- Screenshot: `screenshots/005-froth-analyses.png`
- Title: Froth
- Heading: Wednesday, March 25
- Description: LiveView FrothWeb.AnalysesLive#index. Shows Wednesday, March 25. Preview: ← Wednesday, March 25 → inference dataset rdf 58 analyses Mar 25 Mar 24 Mar 23 Mar 22 Mar 21 Mar 20 Mar 19 Mar 18 Mar 17 Mar 16 Mar 15 Mar 14 Mar 13 Mar 12 Mar 11 Mar 10 Mar 09 Mar 08 Mar 07 Mar 03 Mar 02 Mar 01 Feb 28 Feb 27 Feb 26 Feb 25 Feb 24 Feb 23 Feb 22 Feb 21 Feb 20 Feb 1
- Sample Source: static route

## 6. `GET /froth/analyses/:day`

- URL: https://less.rest/froth/analyses/2026-03-25
- Screenshot: `screenshots/006-froth-analyses-2026-03-25.png`
- Title: Froth
- Heading: Wednesday, March 25
- Description: LiveView FrothWeb.AnalysesLive#index. Shows Wednesday, March 25. Preview: ← Wednesday, March 25 → inference dataset rdf 58 analyses Mar 25 Mar 24 Mar 23 Mar 22 Mar 21 Mar 20 Mar 19 Mar 18 Mar 17 Mar 16 Mar 15 Mar 14 Mar 13 Mar 12 Mar 11 Mar 10 Mar 09 Mar 08 Mar 07 Mar 03 Mar 02 Mar 01 Feb 28 Feb 27 Feb 26 Feb 25 Feb 24 Feb 23 Feb 22 Feb 21 Feb 20 Feb 1
- Sample Source: latest analysis day

## 7. `GET /froth/inference`

- URL: https://less.rest/froth/inference
- Screenshot: `screenshots/007-froth-inference.png`
- Title: Postgrex.Error at GET /froth/inference
- Description: LiveView FrothWeb.InferenceSessionsLive#index. Preview: Postgrex.Error at GET /froth/inference ERROR 42883 (undefined_function) operator does not exist: text = uuid query: SELECT t0."cycle_id", t0."bot_id", t0."chat_id", t0."reply_to", t0."legacy_inference_session_id", a1."status", a1."provider", a1."model", a1."root_span_id", a1."par
- Sample Source: static route

## 8. `GET /froth/inference/:id`

- URL: https://less.rest/froth/inference/01KMKCYQ9J9RJZMVYH42ZESYGX
- Screenshot: `screenshots/008-froth-inference-01kmkcyq9j9rjzmvyh42zesygx.png`
- Title: Postgrex.Error at GET /froth/inference/01KMKCYQ9J9RJZMVYH42ZESYGX
- Description: LiveView FrothWeb.InferenceSessionsLive#show. Preview: Postgrex.Error at GET /froth/inference/01KMKCYQ9J9RJZMVYH42ZESYGX ERROR 42883 (undefined_function) operator does not exist: text = uuid query: SELECT t0."cycle_id", t0."bot_id", t0."chat_id", t0."reply_to", t0."legacy_inference_session_id", a1."status", a1."provider", a1."model",
- Sample Source: latest cycle id

## 9. `GET /froth/dataset`

- URL: https://less.rest/froth/dataset
- Screenshot: `screenshots/009-froth-dataset.png`
- Title: Froth
- Description: LiveView FrothWeb.DatasetLive#index. Preview: Dataset Back 39 Flux fine-tunes Flux fine-tunes: build and run custom AI image models via API 250 Official AI models Official AI models: Always available, stable, and predictably priced 235 Generate videos Use AI to generate videos with an API 75 Generate images Use AI to generat
- Sample Source: static route

## 10. `GET /froth/rdf`

- URL: https://less.rest/froth/rdf
- Screenshot: `screenshots/010-froth-rdf.png`
- Title: Froth
- Description: LiveView FrothWeb.RdfLive#index. Preview: RDF Back Types (0)
- Sample Source: static route

## 11. `GET /froth/wiki`

- URL: https://less.rest/froth/wiki
- Screenshot: `screenshots/011-froth-wiki.png`
- Title: Froth
- Heading: ENCYCLOPÆDIA PALLICA
- Description: LiveView FrothWeb.WikiLive#index. Shows ENCYCLOPÆDIA PALLICA. Preview: ENCYCLOPÆDIA PALLICA A companion to the theory of the pallus & related concepts CCRU Derrida Desiring-Production Hysteria Melancholia Objet petit a Pallus Perversion Phallus Phobia Saussure Seduction Sinthome StudlyCaps The Big I The Clinical Map of the Pallus The Floor The Formu
- Sample Source: static route

## 12. `GET /froth/wiki/:slug`

- URL: https://less.rest/froth/wiki/ccru
- Screenshot: `screenshots/012-froth-wiki-ccru.png`
- Title: Froth
- Heading: ENCYCLOPÆDIA PALLICA
- Description: LiveView FrothWeb.WikiLive#show. Shows ENCYCLOPÆDIA PALLICA. Preview: ENCYCLOPÆDIA PALLICA A companion to the theory of the pallus & related concepts ← Index CCRU Cybernetic Culture Research Unit · Hyperstition · Land, Plant, Fisher, Eshun The Cybernetic Culture Research Unit. Warwick, mid-nineties. Land, Plant, Fisher, Eshun, Mackay. Their entire
- Sample Source: first wiki slug

## 13. `GET /froth/media/:chat_id/:message_id`

- URL: https://less.rest/froth/media/-1003690254489/60963160064
- Screenshot: `screenshots/013-froth-media-1003690254489-60963160064.png`
- Title: 60963160064 (3024×1898)
- Description: Controller FrothWeb.MediaController#show. Chrome rendered a direct image response.
- Sample Source: latest photo/document message

## 14. `GET /froth/bot-context`

- URL: https://less.rest/froth/bot-context
- Screenshot: `screenshots/014-froth-bot-context.png`
- Title: Froth
- Heading: Bot Context Preview
- Description: LiveView FrothWeb.BotContextLive#index. Shows Bot Context Preview. Preview: Bot Context Preview Sample context rendered from shared HEEx templates. This example includes summary text, analyses, and message-linked cycle traces. Context Parts 7 parts Part 1 <summary date="2026-03-04"> The group spent the morning debugging a memory leak in the OTP superviso
- Sample Source: static route

## 15. `GET /froth/follow`

- URL: https://less.rest/froth/follow
- Screenshot: `screenshots/015-froth-follow.png`
- Title: Froth
- Heading: Follow
- Description: LiveView FrothWeb.FollowLive#index. Shows Follow. Preview: EXECUTION READER LIVE TAIL Follow Recent execution history from `events`, projected into a readable run log and kept live with telemetry. SMART RAW ERRORS CLEAR 1427 SHOWN TELEGRAM STREAM 21:04:45.973 TG charlie update ignored type=updateMessageSendSucceeded chat=-1003690254489 P
- Sample Source: static route

## 16. `GET /froth/telemetry`

- URL: https://less.rest/froth/telemetry
- Screenshot: `screenshots/016-froth-telemetry.png`
- Title: Froth
- Heading: Follow
- Description: LiveView FrothWeb.TelemetryLive#index. Shows Follow. Preview: EXECUTION READER LIVE TAIL Follow Recent execution history from `events`, projected into a readable run log and kept live with telemetry. SMART RAW ERRORS CLEAR 1422 SHOWN SYSTEM STREAM 21:04:49.133 WS_PROTO - raw recv false PAYLOAD PARENT 21:04:49.133 BROWSER - event false PAYLO
- Sample Source: static route

## 17. `GET /froth/chat-stats`

- URL: https://less.rest/froth/chat-stats
- Screenshot: `screenshots/017-froth-chat-stats.png`
- Title: Froth
- Heading: Chat Stats
- Description: LiveView FrothWeb.ChatStatsLive#index. Shows Chat Stats. Preview: Chat Stats Per-user contribution by day. Click a name to see their messages. ← 2026-03-25 → 03/25 03/24 03/23 03/22 03/21 03/20 03/19 03/18 03/17 03/16 03/15 03/14 03/13 03/12 03/11 03/10 03/09 03/08 03/07 03/06 03/05 03/04 03/03 03/02 03/01 02/28 02/27 02/26 02/25 02/24 02/23 02
- Sample Source: static route

## 18. `GET /froth/chat-stats/:day`

- URL: https://less.rest/froth/chat-stats/2026-03-25
- Screenshot: `screenshots/018-froth-chat-stats-2026-03-25.png`
- Title: Froth
- Heading: Chat Stats
- Description: LiveView FrothWeb.ChatStatsLive#index. Shows Chat Stats. Preview: Chat Stats Per-user contribution by day. Click a name to see their messages. ← 2026-03-25 → 03/25 03/24 03/23 03/22 03/21 03/20 03/19 03/18 03/17 03/16 03/15 03/14 03/13 03/12 03/11 03/10 03/09 03/08 03/07 03/06 03/05 03/04 03/03 03/02 03/01 02/28 02/27 02/26 02/25 02/24 02/23 02
- Sample Source: latest chat-stats day

## 19. `GET /froth/jobs`

- URL: https://less.rest/froth/jobs
- Screenshot: `screenshots/019-froth-jobs.png`
- Title: Protocol.UndefinedError at GET /froth/jobs
- Description: LiveView FrothWeb.JobsLive#index. Preview: Protocol.UndefinedError at GET /froth/jobs protocol String.Chars not implemented for Map. This protocol is implemented for: Atom, BitString, Date, DateTime, Decimal, Float, Floki.Selector, Floki.Selector.AttributeSelector, Floki.Selector.Combinator, Floki.Selector.Functional, Flo
- Sample Source: static route

## 20. `GET /froth/scene`

- URL: https://less.rest/froth/scene
- Screenshot: `screenshots/020-froth-scene.png`
- Title: Froth
- Heading: Walk regions and corner figures
- Description: LiveView FrothWeb.SceneLive#index. Shows Walk regions and corner figures. Preview: SCENE GEOMETRY Walk regions and corner figures Define where characters can move as polygons, then size a reference person at each corner until the scene feels right. Each corner stores its own person height, and the walking scale inside the region is blended from those corner val
- Sample Source: static route

## 21. `GET /froth/scene/:id`

- URL: https://less.rest/froth/scene/default
- Screenshot: `screenshots/021-froth-scene-default.png`
- Title: Froth
- Heading: Walk regions and corner figures
- Description: LiveView FrothWeb.SceneLive#index. Shows Walk regions and corner figures. Preview: SCENE GEOMETRY Walk regions and corner figures Define where characters can move as polygons, then size a reference person at each corner until the scene feels right. Each corner stores its own person height, and the walking scale inside the region is blended from those corner val
- Sample Source: latest scene id

## 22. `GET /froth/mini/app`

- URL: https://less.rest/froth/mini/app
- Screenshot: `screenshots/022-froth-mini-app.png`
- Title: undefined
- Description: LiveView FrothWeb.ToolLive#landing. Preview: MISSING cycle not found LATEST cycle not found REFRESH CLOSE
- Sample Source: static route

## 23. `GET /froth/mini/tool`

- URL: https://less.rest/froth/mini/tool
- Screenshot: `screenshots/023-froth-mini-tool.png`
- Title: undefined
- Description: LiveView FrothWeb.ToolLive#landing. Preview: MISSING cycle not found LATEST cycle not found REFRESH CLOSE
- Sample Source: static route

## 24. `GET /froth/mini/tool/:ref`

- URL: https://less.rest/froth/mini/tool/cycle_charlie_01KMKCYQ9J9RJZMVYH42ZESYGX
- Screenshot: `screenshots/024-froth-mini-tool-cycle-charlie-01kmkcyq9j9rjzmvyh42zesygx.png`
- Title: undefined
- Heading: Charlie's Lore — The Compressed Memory
- Description: LiveView FrothWeb.ToolLive#show. Shows Charlie's Lore — The Compressed Memory. Preview: DONE 01KMKCYQ9J9R 14 tools cycle 01KMKCYQ9J9RJZMVYH42ZESYGX complete LATEST <summary date="lore"> Charlie's Lore — The Compressed Memory Updated by Charlie on 2026-03-20 from the full chronicle + the March 20 session. The full summaries are preserved in the database. This file is
- Sample Source: latest telegram cycle link

## 25. `GET /froth/mini/codex`

- URL: https://less.rest/froth/mini/codex
- Screenshot: `screenshots/025-froth-mini-codex.png`
- Title: undefined
- Heading: Sessions
- Description: LiveView FrothWeb.CodexLive#index. Shows Sessions. Preview: CODEX LIVE Sessions Pick one session or start a new one. Refresh New Session codex_48e8082f 2026-03-25 21:05 assistant: The rerun is underway. Since the first pass already proved the capture path, I’m mostly watching for a clean finish this time and then I’ll inspect the generate
- Sample Source: static route

## 26. `GET /froth/mini/codex/thread/:thread_id`

- URL: https://less.rest/froth/mini/codex/thread/019d26c2-a755-71b2-b2c8-da004cee6cf3
- Screenshot: `screenshots/026-froth-mini-codex-thread-019d26c2-a755-71b2-b2c8-da004cee6cf3.png`
- Title: undefined
- Heading: Sessions
- Description: LiveView FrothWeb.CodexLive#index. Shows Sessions. Preview: CODEX LIVE Sessions Pick one session or start a new one. Refresh New Session codex_48e8082f 2026-03-25 21:05 assistant: The rerun is underway. Since the first pass already proved the capture path, I’m mostly watching for a clean finish this time and then I’ll inspect the generate
- Sample Source: latest active Codex thread

## 27. `GET /froth/mini/codex/:session_id`

- URL: https://less.rest/froth/mini/codex/codex_48e8082f
- Screenshot: `screenshots/027-froth-mini-codex-codex-48e8082f.png`
- Title: undefined
- Description: LiveView FrothWeb.CodexLive#index. Preview: live ● ready Codex gpt-5.4 xhigh yolo 159.9k/5.7M limits 3% / 25% 17m22s LATEST SYSTEM starting codex... nil DETAILS STATUS session codex_48e8082f nil DETAILS SYSTEM connected nil DETAILS SYSTEM auth ok chatgpt · pro · mikael@brockman.se nil DETAILS THREAD Thread started 019d26c2
- Sample Source: latest persisted Codex session

## 28. `GET /jbo`

- URL: https://less.rest/jbo
- Screenshot: `screenshots/028-jbo.png`
- Title: jbo
- Heading: Search valsi, rafsi, selma'o, glosses, and the links between entries.
- Description: LiveView FrothWeb.JboLive#index. Shows Search valsi, rafsi, selma'o, glosses, and the links between entries.. Preview: LOJBAN LOOKUP Search valsi, rafsi, selma'o, glosses, and the links between entries. The full dictionary is bundled locally and loaded ahead of time, so `/jbo` behaves like a fast reference tool instead of a page that wakes up after you open it. SEARCH coi UI1 bau bangu a'a lojbo
- Sample Source: static route

## 29. `GET /rfc`

- URL: https://less.rest/rfc
- Screenshot: `screenshots/029-rfc.png`
- Title: Froth RFCs
- Heading: Froth RFCs
- Description: Controller FrothWeb.RfcController#index. Shows Froth RFCs. Preview: Froth RFCs RFC Title Status Date Author 0001 FROTH-RFC-0001: In-Browser Video Encoding via WebCodecs PARTIALLY IMPLEMENTED 2026-03-20 Charlie (@charliebuddybot) 0002 FROTH-RFC-0002: Native Multimodal LLM Layer PARTIALLY IMPLEMENTED 2026-03-22 Charlie (@charliebuddybot) 0003 FROTH
- Sample Source: static route

## 30. `GET /rfc/:slug`

- URL: https://less.rest/rfc/0001
- Screenshot: `screenshots/030-rfc-0001.png`
- Title: RFC 0001 — FROTH-RFC-0001: In-Browser Video Encoding via WebCodecs
- Heading: FROTH-RFC-0001: In-Browser Video Encoding via WebCodecs
- Description: Controller FrothWeb.RfcController#show. Shows FROTH-RFC-0001: In-Browser Video Encoding via WebCodecs. Preview: Froth Project RFC 0001 ← All RFCs FROTH-RFC-0001: In-Browser Video Encoding via WebCodecs Status PARTIALLY IMPLEMENTED Author Charlie (@charliebuddybot) Date 2026-03-20 Supersedes The screenshot-to-PNG-to-ffmpeg pipeline Problem Rendering a 4-minute video at 24fps currently requi
- Sample Source: first RFC slug

## 31. `GET /embed/:batch_id`

- URL: https://less.rest/embed/0ce501dd
- Screenshot: `screenshots/031-embed-0ce501dd.png`
- Title: 0ce501dd
- Description: Controller FrothWeb.EmbedController#show. Preview: 0ce501dd Download MP3
- Sample Source: latest podcast batch id

## 32. `GET /embed/:batch_id/audio`

- URL: https://less.rest/embed/0ce501dd/audio
- Screenshot: `screenshots/032-embed-0ce501dd-audio.png`
- Description: Controller FrothWeb.EmbedController#audio. Rendered as audio/mpeg.
- Sample Source: latest podcast batch id

## 33. `GET /reel`

- URL: https://less.rest/reel
- Screenshot: `screenshots/033-reel.png`
- Title: Reels
- Heading: Reels
- Description: Controller FrothWeb.ReelController#index. Shows Reels. Preview: Reels xpath-hour
- Sample Source: static route

## 34. `GET /reel/:id`

- URL: https://less.rest/reel/xpath-hour
- Screenshot: `screenshots/034-reel-xpath-hour.png`
- Title: The XPath Hour
- Description: Controller FrothWeb.ReelController#show. Preview: The XPath Hour So, 0.00 146 phrases
- Sample Source: first reel id

## 35. `GET /news`

- URL: https://less.rest/news
- Screenshot: `screenshots/035-news.png`
- Description: Controller FrothWeb.NewsController#show. Preview: Regional News for Helsinki, Uusimaa, Finland Generated by Grok via Froth SUBJECT: HELSINKI/UUSIMAA 24-HOUR INTEL BRIEF - 24-25 MAR 26: ENERGY CRISIS BITES, YOUTH KNIFE ATTACK, JEF SUMMIT LOOMS, STOCKS BUoyant 1. (C) POLITICAL DEVELOPMENTS. Finnish PM Petteri Orpo hosted Swedish P
- Sample Source: static route

## 36. `GET /froth/voice`

- URL: https://less.rest/froth/voice
- Screenshot: `screenshots/036-froth-voice.png`
- Title: Froth Voice
- Heading: Froth Voice
- Description: Controller FrothWeb.PodcastController#root. Shows Froth Voice. Preview: Froth Voice Generated podcasts with cloned voices. The wrapper is the problem. The payload was always fine. Voice Episodes Voices Create Archive RSS Nikolai & Daniel: The Urbit-Starlink-SDR-Lagrange Alliance Nikolai & Daniel brainstorm a railgun for the blockchain Nikolai on the
- Sample Source: static route

## 37. `GET /froth/voice/voices`

- URL: https://less.rest/froth/voice/voices
- Screenshot: `screenshots/037-froth-voice-voices.png`
- Title: Voices
- Heading: 27 Voice Clones
- Description: Controller FrothWeb.PodcastController#voices. Shows 27 Voice Clones. Preview: Voice Episodes Voices Create Archive RSS 27 Voice Clones NAME CHARACTER LANGUAGE ID alex_qwen_owner_3586 — Swedish qwen-tts-vc-alexen3010-voice-20260219163236138-693c Alex Schulman Alex Schulman Swedish R8_21QSL3ML Alysa Liu — Swedish R8_18JE5205 Ben Shapiro Political commentator
- Sample Source: static route

## 38. `GET /froth/voice/new`

- URL: https://less.rest/froth/voice/new
- Screenshot: `screenshots/038-froth-voice-new.png`
- Title: Create Episode
- Heading: Create Episode
- Description: Controller FrothWeb.PodcastController#new. Shows Create Episode. Preview: Voice Episodes Voices Create Archive RSS Create Episode Script Speaker: alex_qwen_owner_3586 Alex Schulman (Alex Schulman) Alysa Liu Ben Shapiro (Political commentator, fast-talker) Chasing Amy (Amy (Chasing Amy)) dario (Dario Amodei) destiny_qwen_reg Destiny (Steven Bonnell) (St
- Sample Source: static route

## 39. `GET /froth/voice/episodes`

- URL: https://less.rest/froth/voice/episodes
- Screenshot: `screenshots/039-froth-voice-episodes.png`
- Title: Episodes
- Heading: 80 Episodes
- Description: Controller FrothWeb.PodcastController#index. Shows 80 Episodes. Preview: Voice Episodes Voices Create Archive RSS 80 Episodes Cementmaxxing Brainrot BEN_SHAPIRO · 4 SEGMENTS The Sealed Room — A Brainrot Confessional LEX · DARIO · 23 SEGMENTS Hourly: mar20pm9 - The Distance Is the Thing NIKOLAI · DESTINY (STEVEN BONNELL) · 9 SEGMENTS Hourly: mar20pm8 -
- Sample Source: static route

## 40. `GET /froth/voice/episodes/:id`

- URL: https://less.rest/froth/voice/episodes/83
- Screenshot: `screenshots/040-froth-voice-episodes-83.png`
- Title: Cementmaxxing Brainrot
- Heading: Cementmaxxing Brainrot
- Description: Controller FrothWeb.PodcastController#show. Shows Cementmaxxing Brainrot. Preview: Voice Episodes Voices Create Archive RSS Cementmaxxing Brainrot Generating... STATUS queued BATCH 0ce501dd CREATED 2026-03-22 19:11:24 Script ben_shapiro: A man in Thailand turned himself into cement. And he did it twice. The first time, he ate chalk. Not regular chalk. Ukrainian
- Sample Source: latest episode id

## 41. `GET /froth/voice/archive`

- URL: https://less.rest/froth/voice/archive
- Screenshot: `screenshots/041-froth-voice-archive.png`
- Title: Archive — 141 files
- Heading: Audio Archive
- Description: Controller FrothWeb.PodcastController#archive. Shows Audio Archive. Preview: Voice Episodes Voices Create Archive RSS Audio Archive 141 files. 540 MB total. CAPTION SIZE alex sigge diskuterar lineage pallus bertil amy kungsrsten oc 3450KB ↓ huvudskspelaren 1 6276KB ↓ huvudskspelaren 2 8364KB ↓ alex sigge huvudskdespelaren v2 actual detta r de riktiga v2 8
- Sample Source: static route

## 42. `GET /froth/voice/feed.xml`

- URL: https://less.rest/froth/voice/feed.xml
- Screenshot: `screenshots/042-froth-voice-feed-xml.png`
- Description: Controller FrothWeb.PodcastController#feed. Preview: <?xml version="1.0" encoding="UTF-8"?> <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:atom="http://www.w3.org/2005/Atom"> <channel> <title>Froth Voice</title> <link>https://less.rest/froth/voice</link> <atom:link href="https://less.rest/froth/v
- Sample Source: static route

## 43. `GET /api`

- URL: https://less.rest/api
- Screenshot: `screenshots/043-api.png`
- Title: Froth Voice
- Heading: Froth Voice
- Description: Controller FrothWeb.PodcastController#root. Shows Froth Voice. Preview: Froth Voice Generated podcasts with cloned voices. The wrapper is the problem. The payload was always fine. Voice Episodes Voices Create Archive RSS Nikolai & Daniel: The Urbit-Starlink-SDR-Lagrange Alliance Nikolai & Daniel brainstorm a railgun for the blockchain Nikolai on the
- Sample Source: static route

## 44. `GET /api/voices`

- URL: https://less.rest/api/voices
- Screenshot: `screenshots/044-api-voices.png`
- Title: Voices
- Heading: 27 Voice Clones
- Description: Controller FrothWeb.PodcastController#voices. Shows 27 Voice Clones. Preview: Voice Episodes Voices Create Archive RSS 27 Voice Clones NAME CHARACTER LANGUAGE ID alex_qwen_owner_3586 — Swedish qwen-tts-vc-alexen3010-voice-20260219163236138-693c Alex Schulman Alex Schulman Swedish R8_21QSL3ML Alysa Liu — Swedish R8_18JE5205 Ben Shapiro Political commentator
- Sample Source: static route

## 45. `GET /api/podcasts/new`

- URL: https://less.rest/api/podcasts/new
- Screenshot: `screenshots/045-api-podcasts-new.png`
- Title: Create Episode
- Heading: Create Episode
- Description: Controller FrothWeb.PodcastController#new. Shows Create Episode. Preview: Voice Episodes Voices Create Archive RSS Create Episode Script Speaker: alex_qwen_owner_3586 Alex Schulman (Alex Schulman) Alysa Liu Ben Shapiro (Political commentator, fast-talker) Chasing Amy (Amy (Chasing Amy)) dario (Dario Amodei) destiny_qwen_reg Destiny (Steven Bonnell) (St
- Sample Source: static route

## 46. `GET /api/podcasts`

- URL: https://less.rest/api/podcasts
- Screenshot: `screenshots/046-api-podcasts.png`
- Title: Episodes
- Heading: 80 Episodes
- Description: Controller FrothWeb.PodcastController#index. Shows 80 Episodes. Preview: Voice Episodes Voices Create Archive RSS 80 Episodes Cementmaxxing Brainrot BEN_SHAPIRO · 4 SEGMENTS The Sealed Room — A Brainrot Confessional LEX · DARIO · 23 SEGMENTS Hourly: mar20pm9 - The Distance Is the Thing NIKOLAI · DESTINY (STEVEN BONNELL) · 9 SEGMENTS Hourly: mar20pm8 -
- Sample Source: static route

## 47. `GET /api/podcasts/:id`

- URL: https://less.rest/api/podcasts/83
- Screenshot: `screenshots/047-api-podcasts-83.png`
- Title: Cementmaxxing Brainrot
- Heading: Cementmaxxing Brainrot
- Description: Controller FrothWeb.PodcastController#show. Shows Cementmaxxing Brainrot. Preview: Voice Episodes Voices Create Archive RSS Cementmaxxing Brainrot Generating... STATUS queued BATCH 0ce501dd CREATED 2026-03-22 19:11:24 Script ben_shapiro: A man in Thailand turned himself into cement. And he did it twice. The first time, he ate chalk. Not regular chalk. Ukrainian
- Sample Source: latest podcast id

## 48. `GET /api/archive`

- URL: https://less.rest/api/archive
- Screenshot: `screenshots/048-api-archive.png`
- Title: Archive — 141 files
- Heading: Audio Archive
- Description: Controller FrothWeb.PodcastController#archive. Shows Audio Archive. Preview: Voice Episodes Voices Create Archive RSS Audio Archive 141 files. 540 MB total. CAPTION SIZE alex sigge diskuterar lineage pallus bertil amy kungsrsten oc 3450KB ↓ huvudskspelaren 1 6276KB ↓ huvudskspelaren 2 8364KB ↓ alex sigge huvudskdespelaren v2 actual detta r de riktiga v2 8
- Sample Source: static route

## 49. `GET /dev/dashboard`

- URL: https://less.rest/dev/dashboard
- Screenshot: `screenshots/049-dev-dashboard.png`
- Description: Failed to capture route audit screenshot.
- Sample Source: static route
- Error: `"net::ERR_HTTP_RESPONSE_CODE_FAILURE"`

## 50. `GET /dev/dashboard/:page`

- URL: https://less.rest/dev/dashboard/metrics
- Screenshot: `screenshots/050-dev-dashboard-metrics.png`
- Description: Failed to capture route audit screenshot.
- Sample Source: default LiveDashboard page
- Error: `"net::ERR_HTTP_RESPONSE_CODE_FAILURE"`

## 51. `GET /dev/dashboard/:node/:page`

- URL: https://less.rest/dev/dashboard/froth@igloo/processes
- Screenshot: `screenshots/051-dev-dashboard-froth-igloo-processes.png`
- Description: Failed to capture route audit screenshot.
- Sample Source: current node LiveDashboard page
- Error: `"net::ERR_HTTP_RESPONSE_CODE_FAILURE"`
