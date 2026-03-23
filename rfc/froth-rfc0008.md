# FROTH-RFC-0008: Unified Execution Timeline

Status: DRAFT
Author: Charlie (@charliebuddybot)
Date: 2026-03-23
Related: FROTH-RFC-0004 (Execution Spine), FROTH-RFC-0005 (Legible Follow)

## Situation

Froth has three separate execution viewers that show the same family
of events through three different lenses:

1. **TelemetryLive** — raw telemetry events projected through the
   Follow layer (RFC-0005). Has Smart and Raw modes, cycle/span
   pinning, URL-based scope filtering. Sees everything the BEAM
   emits. Does not see Codex sessions. Does not show narrations.

2. **CodexLive** — Codex session viewer. Streams JSONL entries from
   `codex app-server` over PubSub. Has session/thread navigation,
   entry kinds (assistant, tool, reasoning, error, etc.), a prompt
   dock, a Micromanage button. Does not see Anthropic agent cycles.
   Does not see shell tasks. Does not show telemetry spans.

3. **ToolLive** — agent cycle inspector. Triggered by Telegram
   mini-app deep links. Shows agent events, live thinking, live
   text, tool call results with syntax highlighting, narrations.
   Tied to a single cycle. Does not see Codex sessions. Does not
   see other concurrent cycles. Does not see telemetry.

Additionally, the **chat itself** receives narration messages —
the italicized prose lines from `elixir_eval` and `run_shell`
tool calls. These are the only execution traces most observers
see. They flow through `BotAdapter.send_italic` and appear as
regular Telegram messages. They are not connected to any web view.

### What Each View Has That the Others Lack

TelemetryLive:
- Sees all telemetry events across all subsystems
- Has the Follow projector (semantic grouping, noise filtering)
- Has cycle/span scoping with URL persistence
- Has Smart/Raw mode toggle

CodexLive:
- Sees Codex reasoning traces and tool execution
- Has session/thread multiplexing
- Has the prompt dock (interactive input)
- Has entry kind classification (assistant, tool, reasoning)

ToolLive:
- Sees narrations (the italicized intention lines)
- Has syntax-highlighted code and results
- Has live thinking/text streaming
- Has the Telegram mini-app integration (deep-linkable from chat)

Chat narrations:
- Visible to all humans and bots without opening a browser
- Tied to the conversation flow
- Not queryable, not grouped, not filterable

### The Divergence

These four surfaces were built for different moments in the
project's history. TelemetryLive was built when telemetry was
the only observability layer. CodexLive was built when Codex
arrived as a separate tool. ToolLive was built when Telegram
mini-apps became the primary deep-link mechanism. Narrations
were built when chat was the only interface.

Each one works. None of them compose. A Codex session dispatched
by Charlie (RFC dispatch/2) produces events in Codex's JSONL
stream AND telemetry spans AND chat narrations, but no single
view shows all three. The operator must hold three browser tabs
and a Telegram window to follow one unit of work.

## Goal

One LiveView that multiplexes all execution streams into a
single chronological timeline.

## Design

### The Timeline as Primitive

The unified view is not a dashboard. It is a timeline. Every
event — telemetry span, Codex entry, agent message, shell
output line, narration — becomes a timeline entry with:

- `timestamp` (wall clock, monotonic where available)
- `source` (`:telemetry`, `:codex`, `:agent`, `:shell`, `:narration`)
- `scope` (cycle_id, session_id, span_id, task_id — whatever applies)
- `kind` (maps to the entry's semantic type within its source)
- `body` (the rendered content)

The timeline is append-only in live mode. Historical mode loads
from persisted sources (telemetry_events, codex_events,
agent_events, shell task output).

### Source Adapters

Each execution source gets an adapter that normalizes its events
into timeline entries:

**TelemetryAdapter** — wraps the existing Follow projector.
Already does semantic grouping and noise filtering. Entries
carry span_id and cycle_id when available. This is the adapter
that RFC-0005 already mostly built.

**CodexAdapter** — subscribes to Codex PubSub topics. Maps
Codex entry kinds (assistant, tool, reasoning, error, status)
to timeline entries. Carries session_id and thread_id as scope.

**AgentAdapter** — subscribes to agent cycle PubSub topics.
Emits narrations, tool calls, LLM request/response pairs,
thinking blocks. Carries cycle_id. This replaces ToolLive's
direct event subscription.

**ShellAdapter** — subscribes to shell task output. Emits
stdout/stderr lines as timeline entries. Carries task_id.

### Scope Filtering

The timeline supports nested scope filtering:

- No filter: everything, all sources, all scopes
- Cycle filter: all events from one agent cycle (agent events +
  telemetry spans + any Codex sessions dispatched by that cycle +
  any shell tasks started by that cycle)
- Session filter: all events from one Codex session
- Task filter: all events from one shell task
- Span filter: all events within a telemetry span tree

Scopes are composable. "Show me cycle X" includes the Codex
session that cycle dispatched and the shell tasks that session
started. The scope graph is: cycle -> dispatched sessions ->
spawned tasks -> telemetry spans. Walking that graph in either
direction is the primary navigation mechanism.

### The Narration Channel

Narrations currently go to Telegram only. In the unified view,
narrations are timeline entries like everything else. But the
Telegram channel remains — narrations are the only execution
trace that reaches people who are not looking at a browser.

The narration becomes dual-published: once to Telegram (as
today), once to the timeline PubSub. The timeline entry
carries a reference to the Telegram message_id, so clicking
a narration in the web view can deep-link to the chat context.

### Rendering

Each source adapter owns its own rendering. Codex entries
render with their existing kind-based formatting. Agent events
render with syntax-highlighted code blocks and narration
callouts. Telemetry entries render with the Follow projector's
existing smart formatting. Shell output renders as monospace
streams.

The timeline itself is a flat chronological list with source
indicators (colored left border or icon). Scope transitions
(a new cycle starts, a Codex session begins) are rendered as
section headers that can be collapsed.

### Relation to Existing RFCs

**RFC-0004 (Execution Spine)**: The spine provides the durable
persistence model. The timeline provides the presentation model.
When RFC-0004 lands `agent_events` as first-class records, the
AgentAdapter switches from PubSub subscription to database
queries for historical data. The live path remains PubSub.

**RFC-0005 (Legible Follow)**: The Follow projector becomes one
of four source adapters. Its Smart/Raw mode toggle remains
available per-source. The TelemetryLive view becomes a
pre-filtered instance of the unified timeline (scope: telemetry
only).

**RFC-0007 (Triangulated Search)**: When a search fan-out runs
three concurrent provider calls, each produces telemetry spans.
The timeline shows all three in parallel, scoped to the parent
tool call. The operator sees the race.

### Migration Path

Phase 1: Build the timeline entry model and the four source
adapters. Wire them into a new `TimelineLive` view. Keep
TelemetryLive, CodexLive, and ToolLive running unchanged.

Phase 2: Add scope-graph navigation. Clicking a cycle ID in
the timeline pins to that cycle's full execution tree. Clicking
a Codex session pins to that session. The Micromanage button
in Telegram deep-links to the timeline scoped to that session
instead of to CodexLive directly.

Phase 3: Retire TelemetryLive and CodexLive as standalone
views. They become pre-scoped bookmarks into the timeline.
ToolLive becomes the Telegram mini-app entry point that
redirects to a timeline scope.

Phase 4: When RFC-0004 lands, switch historical data loading
from raw telemetry_events to the execution spine tables.
Live streaming remains PubSub-based regardless.

## Non-Goals

- This RFC does not change how Codex sessions work internally.
- This RFC does not change how telemetry is collected.
- This RFC does not add new execution capabilities.
- This RFC does not replace Telegram narrations with web-only
  output.

## The Thesis

The family has one conversation. It happens in Telegram. The
machines have one execution surface. It happens everywhere —
Codex sessions, agent cycles, shell commands, telemetry spans.
The conversation has one view (the chat). The execution surface
has four views and none of them see the whole thing. The
execution surface needs what the conversation already has: one
timeline where everything that happened appears in the order
it happened, and you can scroll.

