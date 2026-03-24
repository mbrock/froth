# FROTH-RFC-0009: Task Wakeup on Completion

Status: DRAFT
Author: Charlie (@charliebuddybot)
Date: 2026-03-24
Related: FROTH-RFC-0004, FROTH-RFC-0008

## Problem

When an agent calls `subscribe_task` followed by `yield`, the cycle
ends cleanly but the agent is never woken up when the task completes.
The wakeup pathway exists — `fire_notifications/1` builds a synthetic
message and casts it to the bot via `Froth.Telegram.Bots.cast/2` —
but the path has at least two failures:

1. **The synthetic message has `sender_id` as a map `%{"user_id" => 0}`
   instead of an integer.** The bot's `start_cycle_from_message/2` calls
   `BotContext.for_message/2`, which may reject or misroute messages
   with a non-standard sender shape. The `reply_to` field is `nil`
   (the synthetic message has no `"id"` key), but `start_cycle/5`
   pattern-matches on `is_integer(reply_to)`, so the function clause
   won't match. **This is the primary bug.** The notification fires
   but the cycle never starts because the synthetic message doesn't
   satisfy the guard.

2. **Codex sessions never call `fire_notifications/1` at all.** Codex
   tasks are dispatched via `Froth.Codex.Task.run/2`, which returns
   `{:ok, session_id}` and forgets. The session broadcasts
   `{:codex_session_updated, session_id}` on every state change via
   PubSub, but nobody subscribes to that on behalf of the dispatching
   agent. When Codex finishes a turn, the agent that dispatched it
   has no way to know.

## Proposed Fix

### Part 1: Fix synthetic message shape

In `fire_notifications/1` (lib/froth/tasks.ex ~line 287), build the
synthetic message with integer fields that satisfy the guards:

```elixir
synthetic_message = %{
  "chat_id" => link.chat_id,
  "id" => 0,                              # satisfies is_integer(reply_to)
  "sender_id" => 0,                       # integer, not map
  "content" => %{
    "text" => %{
      "text" =>
        "[Task completed] #{task_id} #{task.status}.\n\n#{output_preview}"
        |> String.trim()
    }
  }
}
```

In `start_cycle/5`, relax the `is_integer(reply_to)` guard or handle
`reply_to == 0` as "no specific reply target" (send to chat without
quoting a message).

### Part 2: Connect Codex completion to task notifications

When `Froth.Codex.Task.run/2` dispatches a task, it should:

1. Create a Froth.Tasks task entry (via `Froth.Tasks.create/3`)
   tracking the Codex session.
2. Subscribe the dispatching bot+chat to that task (via
   `Froth.Tasks.subscribe_telegram/4`).
3. When the Codex session transitions to idle after a turn
   (detectable via the `codex_session_updated` PubSub broadcast
   in `broadcast_update/1`), call `Froth.Tasks.complete/2` on
   the associated task, which triggers `fire_notifications/1`.

The simplest way: add a `Froth.Codex.TaskWatcher` process (or
integrate into the existing Session GenServer) that:

- On `send_prompt`, marks the associated Froth task as "running".
- On transition to idle after a turn completes, marks it "completed"
  and calls `Froth.Tasks.complete/2`.
- On session crash/exit, marks it "failed" and calls
  `Froth.Tasks.fail/2`.

### Part 3: Wire the reply_to for wakeup messages

When `start_cycle_from_message` receives a wakeup with `reply_to == 0`,
it should send the response to the chat without quoting any message.
In `send_plaintext_response` and the Telegram send path, treat
`reply_to: 0` or `reply_to: nil` as "no reply target."

## Files to Change

- `lib/froth/tasks.ex` — fix synthetic message shape in
  `fire_notifications/1`
- `lib/froth/telegram/bot.ex` — handle `reply_to == 0` in
  `start_cycle/5` and the send path
- `lib/froth/codex/task.ex` — create a Froth.Tasks entry on dispatch,
  subscribe the caller
- `lib/froth/codex/session.ex` — detect turn completion, bridge to
  Tasks.complete/2
- Possibly a new `lib/froth/codex/task_watcher.ex` if we want a
  clean separation

## Testing

After implementation:

1. Start a long-running eval or shell task.
2. Call `subscribe_task` + `yield` from the agent.
3. Wait for the task to complete.
4. Verify the agent wakes up with a new cycle containing the
   completion message.
5. Dispatch a Codex task.
6. Verify the agent is notified when Codex finishes.

## Migration

No schema changes. This is pure runtime wiring. The
`task_telegram_links` table already has the right shape. The
`fire_notifications` function already exists and works — it just
receives messages that fail the guards.

## Safety

The system is live and writing continuously. The synthetic message
fix is safe — it only changes the shape of a message that currently
fails silently. The Codex watcher is additive — it creates new
task entries without touching existing Codex session logic.
