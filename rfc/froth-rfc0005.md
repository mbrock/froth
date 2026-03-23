# FROTH-RFC-0005: Legible Follow and Execution Log Reader

Status: DRAFT
Author: Charlie (@charliebuddybot)
Date: 2026-03-23
Related: FROTH-RFC-0003, FROTH-RFC-0004

## Situation

Froth now has a growing execution surface:

- agent cycles
- LLM requests and streamed edits
- tool lifecycles
- Telegram bot/runtime activity
- background tasks
- provider and transport telemetry

The raw data exists, but the operator experience is still rough.

Today there are two main readers:

- `mix froth.follow`
- `FrothWeb.TelemetryLive`

Both work, but both are still very close to the raw event stream.

`mix froth.follow` currently prints:

- raw event name
- optional duration
- flat metadata key/value pairs

That is useful for debugging internals, but not for following a run.
It forces the human reader to do projection work in their head:

- which cycle or span matters?
- which events are noise and which are milestones?
- which start/stop pair belongs together?
- which tool failure actually changed the outcome?
- which lines are operator-relevant versus transport chatter?

`TelemetryLive` has the same problem in a different shape. It is a
generic table of raw events, not a focused execution-log reader.
It truncates details, has no real semantic grouping, and does not yet
feel like the UI version of `follow`.

RFC-0004 points in the right direction: Froth needs an execution
spine, not just transcripts plus raw telemetry. But even before that
full persistence model lands, the project already needs a much better
way to read what is happening.

The immediate opportunity is strong:

- RFC-0003 now emits explicit `agent.tool.*` lifecycle events
- spans and parent IDs already exist
- `telemetry_events` already gives us durable history
- a future `agent_events` expansion is coming in RFC-0004

The missing piece is a presentation model.

## Goal

Make Froth's live and historical execution traces readable by humans.

Concretely:

- `mix froth.follow` should become the best way to watch a cycle run
- a future LiveView should feel like the same reader in a richer UI
- raw telemetry should remain available, but not be the default view
- formatting logic should be shared, not duplicated between CLI and UI

## Non-Goals

- This RFC does not replace raw telemetry storage.
- This RFC does not require RFC-0004's schema changes first.
- This RFC does not propose persisting every token delta in a UI feed.
- This RFC is not a redesign of the generic Telemetry page into a
  universal observability suite.

## Thesis

Froth should stop rendering raw telemetry directly and instead render
projected follow entries.

The right layering is:

1. collect raw runtime events from telemetry and later `agent_events`
2. project them into a stable semantic `Follow.Entry`
3. render those entries differently in CLI and LiveView

The shared projection layer is the key. Without it:

- `mix froth.follow` gets one set of heuristics
- the LiveView gets a different set of heuristics
- the same event means different things in different readers
- future event-log work in RFC-0004 has no stable consumer model

With it:

- formatting gets better once and benefits both readers
- the app can mix live telemetry with persisted event rows
- the same execution vocabulary can power search, filtering, grouping,
  and UI navigation

## Problem With The Current Readers

### 1. Raw event names are too low-level

This:

    froth.agent.tool.completed duration=28123456 tool_name=froth_echo ...

is mechanically correct but cognitively noisy.

Operators usually want:

    tool froth_echo completed 28ms

plus a small number of relevant details.

### 2. Metadata is unprioritized

Current output gives every metadata field the same visual weight.
Important fields like:

- `cycle_id`
- `tool_name`
- `tool_use_id`
- `error`
- `model`
- `usage`

get mixed together with lower-value plumbing fields.

### 3. There is no semantic grouping

The current readers do not really understand:

- span trees
- cycle boundaries
- think/tool alternation
- task lifecycle
- error severity

So humans have to infer the shape of the run from a firehose.

### 4. CLI and LiveView would currently drift

If we improve only `mix froth.follow`, the web reader will stay raw.
If we improve only the LiveView, the terminal reader stays second-rate.
The shared model should come first.

## Proposed Design

### 1. Introduce a shared projection layer

Add a `Froth.Follow` namespace with modules along these lines:

- `Froth.Follow.Entry`
- `Froth.Follow.Projector`
- `Froth.Follow.Renderer`
- `Froth.Follow.Source`

`Froth.Follow.Entry` should represent a human-facing event row, not a
raw telemetry tuple. Example fields:

- `id`
- `at`
- `family`
- `kind`
- `level`
- `scope`
- `summary`
- `detail`
- `duration_ms`
- `cycle_id`
- `span_id`
- `parent_id`
- `tool_use_id`
- `message_id`
- `raw`

The important shift is that `summary` and `detail` are already
projected for human reading.

### 2. Project raw events into semantic families

Raw event names should map into a smaller semantic vocabulary.

Example families:

- `cycle`
- `think`
- `tool`
- `llm`
- `telegram`
- `task`
- `transport`
- `error`

Example projections:

- `froth.agent.cycle.start` -> `cycle started`
- `froth.agent.tool.started` -> `tool <name> started`
- `froth.agent.tool.completed` -> `tool <name> completed`
- `froth.agent.tool.failed` -> `tool <name> failed`
- `froth.agent.tool.timed_out` -> `tool <name> timed out`
- `froth.tasks.completed` -> `task <id> completed`
- `froth.http.sse.text_delta` -> hidden in smart mode, visible in raw mode

The point is not to lose the raw event. The point is to provide a
semantic default.

### 3. Make "smart mode" the default for follow

`mix froth.follow` should default to a smart view, not raw telemetry.

Smart mode should:

- collapse noisy transport events
- highlight boundaries and failures
- prefer semantic summaries over raw metadata dumps
- keep stable columns so the eye can scan quickly

Suggested modes:

- `smart` default operator view
- `raw` exact telemetry view
- `errors` only warnings/failures/timeouts

### 4. Give entries stable visual slots

Each rendered line should have a predictable shape:

    TIME  SCOPE  SUMMARY  DETAIL

For example:

```text
14:58:01.123  cycle 01J...   cycle started              model=claude-opus-4-6
14:58:01.456  think          thinking started
14:58:02.091  tool echo      froth_echo started         call=toolu_...
14:58:02.119  tool echo      froth_echo completed 28ms result=text
14:58:02.403  llm            response completed 311ms   in=842 out=119
14:58:02.418  tool shell     run_shell timed out 30000ms
14:58:02.420  cycle 01J...   cycle failed               tool timed out after 30000ms
```

This is much easier to read than the current "event name plus bag of
keys" style.

### 5. Separate primary detail from raw detail

Each projected entry should expose:

- a primary summary for fast scanning
- a small detail string for top-priority fields
- the full raw event for drill-down

In CLI smart mode, show summary + small detail.
In CLI raw mode, show the whole raw payload.
In LiveView, show summary by default and raw JSON in a side panel or
expandable drawer.

### 6. Correlate by cycle and span by default

Follow readers should understand correlation, not just printing order.

Important scope identifiers:

- `cycle_id`
- `span_id`
- `parent_id`
- `tool_use_id`
- `task_id`
- `message_id`

The shared projector should normalize those IDs and surface them in a
consistent place. That lets both CLI and UI offer:

- follow one cycle
- filter to one span subtree
- jump from a tool failure to related events
- show only entries related to a given task or message

### 7. Build the LiveView on the same entries

The future LiveView should not be another generic telemetry table.
It should be a real execution-log reader.

Suggested structure:

- left rail for high-level filters and saved scopes
- center timeline of projected follow entries
- right detail pane for raw JSON, spans, and linked records

Important UI behaviors:

- stream new entries live
- pin to a cycle/span/tool/task
- pause/resume live updates
- toggle smart/raw view
- expand a row into raw event payload
- group or fold uninteresting transport chatter
- deep-link by cycle ID or span ID

This can begin on top of `telemetry_events` and later incorporate
RFC-0004's richer `agent_events` without changing the UI model.

### 8. Keep raw telemetry as an escape hatch

The system should never trap operators in a projected view.

Both readers should keep a raw mode because:

- projector bugs happen
- new event types will arrive before they are beautifully formatted
- debugging sometimes needs the exact payload

The rule should be:

- smart mode for default readability
- raw mode for exact truth

### 9. Design for mixed live and historical sources

The same follow entry model should be usable with:

- live telemetry attached through `:telemetry.attach_many`
- persisted rows from `telemetry_events`
- future typed rows from `agent_events`

That means the projection API should accept either:

- raw telemetry tuples
- persisted telemetry rows
- future execution-log rows

This is important because the LiveView will want both:

- a historical bootstrapped timeline
- live appended updates

## Concrete Near-Term Work

### Phase 1: Shared projector and renderer

- extract formatting logic out of `Mix.Tasks.Froth.Follow`
- define `Follow.Entry`
- implement smart/raw rendering
- add semantic projections for current high-value families:
  - `agent`
  - `tool`
  - `llm`
  - `tasks`
  - `telegram`

### Phase 2: Upgrade `mix froth.follow`

- make smart mode the default
- add `--raw`
- add `--errors`
- add filters by cycle/span/prefix
- improve duration and summary formatting

### Phase 3: Build `FollowLive`

- stream projected entries in a LiveView
- support historical boot plus live append
- add row expansion for raw payload
- add cycle/span pinning and text filtering

### Phase 4: Integrate RFC-0004 data

As `agent_events` becomes a real execution log, the projector should
start preferring typed execution events over inferred raw telemetry
where possible.

## Why This Should Happen Before A Bigger UI Rewrite

The follow/output problem is mostly not a CSS problem.
It is a semantic projection problem.

If Froth jumps straight to a fancy LiveView without first defining the
shared event-entry model, it will only create a prettier version of
the same raw unreadability.

The projector layer is the leverage point.

## Recommendation

Do this in the following order:

1. extract a shared follow projection layer
2. make `mix froth.follow` excellent in smart mode
3. build `FollowLive` on that same projected entry stream
4. connect the same reader to RFC-0004's future execution log

That creates one coherent operator experience across terminal, web,
live telemetry, and persisted history.

## References

- `lib/mix/tasks/froth.follow.ex`
- `lib/froth_web/live/telemetry_live.ex`
- `lib/froth/telemetry/store.ex`
- `lib/froth/telemetry/span.ex`
- `lib/froth/agent/worker.ex`
- `rfc/froth-rfc0003.md`
- `rfc/froth-rfc0004.md`
