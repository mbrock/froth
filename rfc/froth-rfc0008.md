# FROTH-RFC-0008: Unified Event Table

Status: IMPLEMENTED
Author: Charlie (@charliebuddybot)
Date: 2026-03-23
Supersedes: RFC-0004 agent_events table (deprecated)

## Situation

Froth has two event tables recording overlapping facts:

1. **telemetry_events** — the firehose. Columns: id (uuid),
   event (varchar), measurements (jsonb), metadata (jsonb),
   inserted_at, span_id, parent_id. Written by
   Froth.Telemetry.Store via the BEAM :telemetry bus. Sees
   everything. Schema-free payloads.

2. **agent_events** — created by RFC-0004. Columns: id (uuid),
   cycle_id, head_id, seq, kind, span_id, parent_span_id,
   message_id, tool_use_id, data_json (jsonb), blob_ref,
   inserted_at. Written by Froth.Agent.append_event/2.
   Agent-specific typed columns that are null for everything
   else.

The worker dual-writes: every agent execution event fires a
telemetry span AND inserts an agent_events row. Same span IDs
in both places. Two tables recording the same facts with
different column layouts.

Three separate viewers (TelemetryLive, CodexLive, ToolLive)
read from different subsets. No single view sees everything.

## Goal

One table. One timeline. JSONB payloads. No nullable slop
columns for domain-specific fields.

## Design

### Step 1: Rename telemetry_events → events

Migration:

    rename table(:telemetry_events), to: table(:events)

Update all index names accordingly. Update Froth.Telemetry.Store
to write to "events" instead of "telemetry_events".

### Step 2: Enrich metadata JSONB

Agent execution data that RFC-0004 put in typed columns goes
into the metadata JSONB instead:

    metadata: %{
      "kind" => "tool.completed",
      "cycle_id" => "01ABCDEF...",
      "head_id" => "01ABCDEF...",
      "tool_use_id" => "toolu_abc123",
      "blob_ref" => "sha256:...",
      "seq" => 42,
      ...domain-specific payload...
    }

The only real columns on the events table are:

    id          uuid        NOT NULL  (primary key)
    event       varchar     NOT NULL  (dot-joined name, e.g. "froth.agent.cycle")
    span_id     varchar     NULL      (already a column — keep it)
    parent_id   varchar     NULL      (already a column — keep it)
    measurements jsonb      NULL      (timing, counts)
    metadata    jsonb       NULL      (everything else)
    inserted_at timestamp   NOT NULL

span_id and parent_id stay as columns because they are the
join keys for span tree traversal and they apply to every
event source, not just agents. Everything domain-specific
goes in JSONB.

### Step 3: Rewrite Agent.append_event/2

Instead of inserting into agent_events, it calls
Froth.Telemetry.Store or writes directly to events:

    Froth.Repo.insert_all("events", [%{
      id: Ecto.UUID.generate(),
      event: "froth.agent.#{kind}",
      span_id: attrs.span_id,
      parent_id: attrs.parent_span_id,
      measurements: %{},
      metadata: %{
        "kind" => kind,
        "cycle_id" => cycle_id,
        "head_id" => head_id,
        "tool_use_id" => tool_use_id,
        "data" => data,
        "blob_ref" => blob_ref,
        "seq" => next_seq
      },
      inserted_at: DateTime.utc_now()
    }])

The blob offloading logic from RFC-0004 remains — payloads
over 8KB get hashed, stored in ObjectStore, and replaced
with a summary in the metadata. That logic is good. It just
writes to the wrong table.

### Step 4: Drop agent_events

Migration:

    drop table(:agent_events)

Remove Froth.Agent.Event schema module.

### Step 5: Update cycle_usage view

The cycle_usage view currently joins through agent_events.
Rewrite it to query the events table filtering on
metadata->>'cycle_id' and event LIKE 'froth.agent.%'.

### Step 6: Add GIN index on metadata

    create index(:events, [:metadata], using: "gin")

This makes queries like
`WHERE metadata->>'cycle_id' = ?` and
`WHERE metadata->>'kind' = ?` fast without adding columns.

### Step 7: Unified LiveView

One TimelineLive that reads from the events table with
filters:

- No filter: everything, all sources, all scopes
- Cycle filter: WHERE metadata->>'cycle_id' = ?
- Session filter: WHERE metadata->>'session_id' = ?
- Span filter: span tree traversal via span_id/parent_id
- Source filter: WHERE event LIKE 'froth.agent.%' etc.

The existing TelemetryLive, CodexLive, and ToolLive become
pre-filtered bookmarks into this one view.

## Migration Strategy

Phases 1-4 (rename, enrich, rewrite, drop) are one migration
and one code change. No transitional dual-write period. The
agent_events table has existed for less than an hour. There
is no historical data worth preserving — any agent_events
rows can be re-derived from telemetry_events which recorded
the same spans.

Phase 5-7 (view rewrite, GIN index, unified LiveView) can
land separately.

## What RFC-0004 Got Right

- Cycle status tracking on the cycles table (keep)
- Blob offloading for large payloads (keep, redirect to events)
- Event sequencing per cycle (keep, in metadata)
- The worker's boolean finalization gates (keep)
- The LiveView modeline compaction (keep)

## What RFC-0004 Got Wrong

- Created a new table instead of enriching the existing one
- Added nullable typed columns for domain-specific fields
- Duplicated span_id/parent_span_id as separate column names

## Non-Goals

- This does not change how the BEAM :telemetry bus works
- This does not change cycle lifecycle management
- This does not add new event sources
- This does not touch Codex session management

## The Thesis

One table called events. Span tree as columns because it is
universal. Everything else as JSONB because it is not. The
table that already exists gets promoted, not replaced. Fewer
tables, not more.
