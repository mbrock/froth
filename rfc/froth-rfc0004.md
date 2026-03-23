# FROTH-RFC-0004: Agent Execution Spine

Status: DRAFT
Author: Charlie (@charliebuddybot)
Date: 2026-03-23
Related: FROTH-RFC-0002, FROTH-RFC-0003

## Situation

RFC-0002 pushes Froth toward a native multimodal LLM layer.
RFC-0003 fixes a concrete agent-runtime bug around parallel tool
execution. Both are necessary. Neither is the next bottleneck.

The next bottleneck is that execution state is split across four
different worlds:

- in-memory process state inside `Froth.Agent.Worker`
- semantic transcript state in `agent_messages`
- minimal sequencing state in `agent_events`
- low-level span data in `telemetry_events`

That split was fine while the agent subsystem was small. It is
starting to hurt now.

`agent_cycles` currently stores almost nothing except an ID and
timestamps. `agent_events` is only a head pointer plus a sequence
number. `agent_messages` stores the semantic content and some
metadata, but not the runtime structure of the cycle. Telemetry has
the opposite problem: rich runtime detail exists, but it is not the
primary data model of the agent subsystem. It is just a span stream.

This means Froth can reconstruct a transcript, but not a run.

Questions that should be first-class are currently awkward:

- What exact resolved config did this cycle run with?
- Which LLM calls happened, in what order, with what latency and
  usage?
- Which tool calls started, succeeded, failed, or timed out?
- What blob or media payloads were involved, and where are they
  stored?
- Which telemetry spans correspond to which cycle turns?
- Can a cycle be resumed, retried, or inspected without scraping the
  transcript?

As multimodal support grows, this gets worse. If media blobs and raw
vendor payloads live inline in JSONB transcript rows, storage gets
hot, indexes get worse, and the database becomes the accidental blob
store.

At the same time, the Telegram-facing side of the system is already
moving toward normalized message history plus linked cycle traces.
That is the right direction. The persistence model should now catch
up to the runtime model.

## Goal

Build a durable execution spine for Froth's LLM and agent runtime:

- semantic messages remain available as the transcript
- runs become first-class records, not inferred after the fact
- tool calls and LLM calls become queryable operational units
- telemetry spans attach cleanly to persisted execution records
- large payloads and media move out of hot JSONB rows
- app-specific linkage such as Telegram remains possible without
  defining the core runtime model

## Non-Goals

- This RFC does not replace Postgres with a data lake.
- This RFC does not redesign prompt construction.
- This RFC does not require every streamed token delta to be persisted.
- This RFC does not remove provider-specific traces or telemetry.
- This RFC is not a proposal for distributed agent scheduling yet.

## Thesis

The next layer after native provider adapters is not another wrapper.
It is an execution spine.

Froth should treat "agent cycle", "LLM call", "tool invocation",
"semantic message", "blob/media artifact", and "telemetry span" as
connected pieces of one run. Today those pieces exist, but they do
not line up in one durable model.

The right move is:

1. make `agent_cycles` a real run record
2. turn `agent_events` into a durable execution log
3. keep `agent_messages` as the semantic transcript
4. move large blobs and raw payloads out of transcript tables
5. persist enough config and provenance to make runs inspectable and
   resumable

## Proposed Changes

### 1. Promote `agent_cycles` from ID holder to run record

`agent_cycles` should become the durable summary of a run.

It should carry fields like:

- `status` (`queued`, `running`, `waiting_on_tools`, `completed`,
  `failed`, `cancelled`)
- resolved `provider`
- resolved `model`
- `root_span_id`
- `parent_span_id`
- `config_json`
- `system_prompt_ref` or `system_prompt_hash`
- `toolset_hash`
- aggregate `usage`
- aggregate `cost_usd`
- `error`
- `started_at`
- `finished_at`

The key point is that a cycle should be inspectable without replaying
the whole transcript and without scraping telemetry to recover basic
facts about what happened.

### 2. Turn `agent_events` into the execution log

`agent_events` should stop being only "head moved to message X".
That information is useful, but it is not enough.

Instead, `agent_events` should be an append-only log of meaningful
runtime transitions. Example kinds:

- `cycle.started`
- `llm.requested`
- `llm.completed`
- `tool.started`
- `tool.completed`
- `tool.failed`
- `message.appended`
- `cycle.completed`
- `cycle.failed`

Each event row should be able to carry:

- `cycle_id`
- `seq`
- `kind`
- `span_id`
- `parent_span_id`
- `message_id`
- `tool_use_id`
- `data_json`
- `blob_ref`

This does not mean persisting every token delta. The log should store
turn and operation boundaries, not an unbounded firehose of tiny
events. Live token streaming can remain PubSub + telemetry.

### 3. Keep `agent_messages` as the semantic transcript

`agent_messages` is still the right place for the semantic content
chain:

- user messages
- assistant messages
- tool results
- multimodal content blocks

But it should stop carrying the burden of also being the runtime
execution log. It is the transcript, not the scheduler, not the
trace store, and not the blob store.

This also keeps the message model aligned with RFC-0002:
providers produce semantic Froth content, and the transcript stores
that semantic content.

### 4. Persist resolved config and provenance explicitly

Today the agent runtime resolves provider/model/system/tools in
memory and then mostly forgets the exact resolved shape.

That should be persisted at cycle start. At minimum:

- resolved provider/module
- resolved model
- resolved tool specs
- thinking / effort settings
- app-level context identifiers
- bot/chat linkage where relevant

This is important for:

- reproducibility
- debugging
- cost analysis
- future replay or resume

The stored form does not need to inline huge prompts or blobs. Hashes
plus blob refs are enough if the underlying content is retrievable.

### 5. Add out-of-line blob storage for raw payloads and media

Raw vendor requests, raw vendor responses, SSE transcripts, and media
blobs should not live inline in the hot path tables by default.

The right pattern is:

- Postgres stores metadata, previews, hashes, and refs
- object storage stores the heavy payload

Examples of things that should become refs instead of inline JSONB:

- base64 image outputs
- uploaded PDFs
- full raw API request/response bodies
- captured SSE transcripts for fixture/replay/debug use

This matters for both cost and performance. Multimodal support will
otherwise turn normal operational tables into accidental file
archives.

### 6. Make telemetry and execution records joinable by design

Froth already emits spans around:

- LLM requests
- HTTP requests
- SSE events
- agent cycles
- agent think phases
- LLM edit projection

That is good. The missing piece is that the persisted agent runtime
records should reference those spans directly.

The rule should be simple:

- every persisted cycle has a root span ID
- every persisted LLM call or tool invocation has a span ID
- every execution-log event may point at the span that emitted it

This lets the UI answer both semantic and operational questions:

- what did the model say?
- how long did it take?
- which provider call produced it?
- where did the error happen?

### 7. De-emphasize legacy inference-session snapshots

The long-term direction should be:

- normalized Telegram messages
- normalized agent cycles
- explicit cycle links
- derived summaries and views

not cumulative conversation snapshots as the primary runtime record.

`telegram_cycle_links` is already a step in this direction. Keep that
idea. Continue moving app-specific linkage into thin relation tables
around a stronger core agent runtime model.

## Schema Sketch

One plausible near-term shape:

    agent_cycles
      id
      status
      provider
      model
      root_span_id
      parent_span_id
      config_json
      usage_json
      cost_usd
      error
      started_at
      finished_at
      inserted_at

    agent_events
      id
      cycle_id
      seq
      kind
      span_id
      parent_span_id
      message_id
      tool_use_id
      data_json
      blob_ref
      inserted_at

    agent_messages
      id
      parent_id
      role
      content_json
      metadata_json
      inserted_at

    telegram_cycle_links
      cycle_id
      bot_id
      chat_id
      reply_to
      legacy_inference_session_id

This is intentionally conservative. It evolves the tables Froth
already has instead of requiring a whole new runtime subsystem at
once.

## Migration Plan

Phase 1: Add `status`, resolved config, usage, error, and span fields
         to `agent_cycles`.

Phase 2: Expand `agent_events` into a typed execution log while
         keeping the existing head-tracking semantics working during
         migration.

Phase 3: Persist LLM-call and tool-invocation boundaries as events
         from `Agent.Worker`.

Phase 4: Introduce blob refs for large payloads and media, with
         object-store-backed storage for the heavy data.

Phase 5: Update the cycle UI and related views to read cycle/event
         metadata directly instead of reconstructing everything from
         transcript scraping.

Phase 6: Reduce dependence on legacy inference-session snapshots and
         keep them only as migration/backfill compatibility.

## Consequences

### Benefits

- Froth gets a durable model of execution, not just transcripts.
- Multimodal content stops threatening the hot operational tables.
- Debugging gets easier because config, spans, tool calls, and LLM
  turns can be queried directly.
- Resume/retry/cancel becomes architecturally possible instead of
  bolted on later.
- App-specific consumers like Telegram can link into the runtime
  model without defining it.

### Costs

- More schema and migration work.
- More explicit separation between transcript rows and blob storage.
- Temporary duplication while old and new persistence paths coexist.
- More care needed around retention, compaction, and object-store GC.

## Recommendation

Do not spend the next phase only adding more provider features.

The next phase should build the execution spine in this order:

1. richer `agent_cycles`
2. typed `agent_events`
3. explicit LLM/tool operation records via events
4. blob refs for large payloads
5. UI and query paths that consume the new records directly

That gives RFC-0002 somewhere durable to land and gives RFC-0003 a
runtime model worthy of parallel execution.
