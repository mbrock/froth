# FROTH-RFC-0003: Parallel Tool Execution

Status: DRAFT
Author: Charlie (@charliebuddybot)
Date: 2026-03-23
Related: FROTH-RFC-0004

## Problem

When an agent response contains N tool calls, `Froth.Agent.Worker`
does the obvious thing: it spawns N concurrent Tasks.

The concurrency stops there.

Each Task immediately calls the same GenServer:

    GenServer.call(worker.config.tool_executor,
      {:execute, tool_use, context})

In the Telegram bots, `tool_executor` is the bot process. That
process handles:

    handle_call({:execute, %ToolUse{} = tool_use, context}, ...)

which means all tool executions are serialized through one mailbox.

So the current shape is:

    worker spawns N Tasks
      -> all N Tasks queue on one GenServer.call
      -> bot executes tool 1
      -> tool 2 waits
      -> tool 3 waits
      -> ...

The result is the worst of both worlds:

- the worker thinks it is doing parallel tool execution
- the bot process is actually doing serialized tool execution
- the queue is governed by the OTP default `GenServer.call` timeout
  of 5000ms

If tool call #1 takes long enough, tool call #2 can fail before it
ever starts running.

## Why This Is Happening

The serialization is not intentional. It is a consequence of the bot
process wearing two hats:

1. it is the Telegram event router and state owner
2. it is also the tool executor

Some of that state is genuinely needed by tools:

- `chat_id`
- `reply_to`
- `session_id`
- sent-message tracking
- cycle control-prompt bookkeeping
- mid-cycle message injection
- task registration and error tracking

But needing state access is not the same as needing serialized
execution.

The code path today mixes three different responsibilities inside one
GenServer call:

1. gather the execution context
2. perform the actual tool work and network I/O
3. mutate bot state based on the result

That is the real bug.

## A Second Bug Hidden Inside the First One

The current draft of this RFC could tempt a one-line fix:

    GenServer.call(..., :infinity)

That does remove the accidental 5000ms timeout. But in the current
code there is no separate worker-owned timeout for tool tasks.

So today:

- `5000ms` is an accidental timeout
- `:infinity` would become an accidental non-timeout

Both are wrong.

Timeout policy should belong to `Froth.Agent.Worker`, because the
worker owns the lifecycle of the tool tasks.

## Requirements

Any real fix should satisfy all of these:

1. Tool work should run in parallel when the tools are independent.
2. Bot state must remain internally consistent.
3. External side effects should not require the bot GenServer to sit
   blocked on network I/O.
4. Timeouts must be explicit and owned by the worker, not inherited
   from `GenServer.call`.
5. The model should compose with RFC-0004's execution-log and
   telemetry direction.

## Proposed Architecture

### 1. Move timeout ownership into `Agent.Worker`

`Agent.Worker` should own tool deadlines explicitly.

Add a `tool_timeout_ms` config value and have the worker schedule a
timeout per invocation. If a tool exceeds its deadline:

- the worker terminates the task
- the worker records a failed tool result
- the cycle continues or fails according to policy

Only after this exists should the internal `GenServer.call` timeout be
set to `:infinity`, because at that point the worker is the owner of
the deadline.

### 2. Split tool execution into `prepare`, `execute`, and `commit`

The core change is to separate state access from work.

#### Prepare

The bot process handles a fast call that:

- validates the tool request
- snapshots the execution context
- reserves any state that must be claimed atomically
- returns an execution capsule

This step should not perform network I/O or long-running work.

Example outputs of prepare:

- `chat_id`
- `reply_to`
- `session_id`
- bot identity
- cycle metadata
- whether a control prompt should be shown
- whether narration should be sent

#### Execute

The worker Task executes the tool outside the bot GenServer using the
prepared capsule.

This is where:

- `Tools.execute/5`
- shell execution
- eval execution
- outbound message sends
- object-store access
- HTTP calls

should happen.

Execution returns both a result and a list of state effects.

#### Commit

After execution completes, the bot process handles a fast commit step
that applies the serialized state mutations:

- `track_sent_message`
- `put_last_tool_error`
- `register_cycle_task`
- clearing or consuming `mid_cycle_messages`
- any bookkeeping around cycle prompts and task tracking

This preserves state consistency without forcing the actual work
through one mailbox.

## Concrete Shape

One plausible interface:

    {:ok, capsule, prepare_effects} =
      GenServer.call(executor, {:prepare_tool, tool_use, context}, :infinity)

    Task.Supervisor.async_nolink(TaskSupervisor, fn ->
      outcome = Froth.Agent.ToolRunner.execute(tool_use, capsule, prepare_effects)
      {:tool_result, tool_use.id, outcome}
    end)

Then on completion:

    GenServer.cast(executor, {:commit_tool, tool_use.id, outcome.commit_effects})

Where `outcome` contains:

- semantic tool result content
- `is_error`
- `commit_effects`
- telemetry metadata

## Why This Fits the Current Code

The existing bot code already reveals the correct split.

`execute_tool_call/3` currently mixes together:

- pure context resolution
- long-running tool work via `Tools.execute`
- outbound Telegram sends
- state mutation via helpers like `track_sent_message`
- follow-up state mutation via `maybe_track_task_from_result`
  and `maybe_track_tool_error`

Those should become separate phases instead of one blocking call.

Even the special cases point in the same direction:

- `send_message` does network I/O plus sent-message bookkeeping
- `run_shell` and `elixir_eval` need control-prompt reservation and
  optional narration, but not a blocked bot mailbox
- `maybe_inject_mid_cycle_messages/2` is a commit concern, not an
  execution concern

## What Not To Do

### Not just "increase the timeout"

Changing `5000` to `30000` reduces pain but keeps the architecture
wrong. It preserves serialization and leaves the timeout policy in
the wrong layer.

### Not just `:infinity` without worker deadlines

That only swaps one accidental policy for another.

### Not a process pool first

A pool of tool executors may make sense later, but it does not solve
the fact that execution, state access, and commit are currently
collapsed into one operation. Fix the boundary first.

## Migration Plan

Phase 1: Add explicit `tool_timeout_ms` to `Agent.Config` and make
         `Agent.Worker` own tool deadlines.

Phase 2: Set internal `GenServer.call` timeouts for tool execution
         to `:infinity`, now that the worker owns the deadline.

Phase 3: Replace `{:execute, tool_use, context}` with a `prepare`
         step that returns a lightweight execution capsule.

Phase 4: Execute tools in Tasks outside the bot GenServer and return
         structured outcomes plus commit effects.

Phase 5: Add a `commit` step in the bot process for serialized state
         mutation.

Phase 6: Emit `tool.started`, `tool.completed`, `tool.failed`, and
         `tool.timed_out` events in a form that can attach cleanly to
         RFC-0004's execution spine.

## Consequences

### Benefits

- Parallel tool execution becomes real, not performative.
- Tool timeouts become explicit and debuggable.
- Bot state remains consistent without forcing network I/O through one
  mailbox.
- The execution model becomes a better fit for persistence and
  telemetry.

### Costs

- More moving parts in the tool-execution path.
- A new prepared execution capsule / commit-effects abstraction.
- Some tool behavior currently expressed as direct state mutation will
  need to be refactored.

## Recommendation

Do this in two deliberate steps:

1. move timeout ownership into the worker immediately
2. then split tool execution into `prepare`, `execute`, and `commit`

That fixes the current failure mode without pretending the real issue
was just a magic number.

## References

- `lib/froth/agent/worker.ex` (`start_tools/2`)
- `lib/froth/telegram/bot.ex` (`handle_call({:execute, ...})`)
- `lib/froth/telegram/bot.ex` (`execute_tool_call/3`)
- `lib/froth/telegram/bot.ex` (`maybe_inject_mid_cycle_messages/2`)
- `lib/froth/telegram/bot.ex` (`track_sent_message/3`)
- `lib/froth/telegram/bot.ex` (`put_last_tool_error/2`)
