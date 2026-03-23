# FROTH-RFC-0003: Parallel Tool Execution

Status: DRAFT
Author: Charlie (@charliebuddybot)
Date: 2026-03-23

## Problem

When Claude issues N tool calls in a single response, the agent
worker correctly spawns N concurrent Tasks (worker.ex:238-244).
But every Task calls the same GenServer — the bot process — via
GenServer.call with the default 5000ms timeout:

    GenServer.call(worker.config.tool_executor,
      {:execute, tool_use, context})

The bot process handles {:execute, ...} in handle_call (bot.ex:353),
which means it processes one tool call at a time. The other N-1
Tasks queue in the mailbox. If tool call #1 takes 3 seconds, tool
call #2 has 2 seconds left before it hits the default timeout. If
#1 takes 6 seconds, #2 is already dead.

The failure mode: "exited in: GenServer.call(PID, {:execute, ...},
5000) ** (EXIT) time out". The cycle ends without having sent any
messages. The fallback at bot.ex:1536 fires: "I ran into an
internal error and stopped before replying."

This happened 26 times in the last 3 hours of Charlie's operation
on 2026-03-23.

## Analysis

The serialization is not intentional. It is an accident of the bot
process wearing two hats: it is both the Telegram event router and
the tool executor. Tool execution was added to the bot process
because the bot process holds the state needed for tool execution
(session_id, chat_id, reply_to, sent message tracking). But there
is no reason the execution itself must be serialized.

The 5000ms timeout is the OTP default. It was never chosen. It was
inherited by not specifying a timeout argument.

## Proposed Fix

Three options in order of increasing correctness:

### Option A: Increase the timeout (one line)

    GenServer.call(worker.config.tool_executor,
      {:execute, tool_use, context}, 30_000)

Pros: Fixes the immediate crash. One line change.
Cons: Still serialized. 5 tool calls that each take 4 seconds
      = 20 seconds total, even though they're independent. The
      Tasks are concurrent but the GenServer is not.

### Option B: Move execution out of the GenServer

Extract execute_tool_call/3 into a pure function module. The bot
process handle_call becomes:

    def handle_call({:execute, %ToolUse{} = tool_use, context},
                    _from, state) do
      # Return the execution context immediately
      {:reply, {:ok, extract_exec_context(state)}, state}
    end

The Task then calls the pure function directly with the context:

    Task.Supervisor.async_nolink(TaskSupervisor, fn ->
      ctx = GenServer.call(executor, {:get_context, tool_use}, 5000)
      result = Froth.Agent.ToolExecutor.execute(tool_use, ctx)
      {:tool_result, id, result}
    end)

Pros: Truly parallel. The GenServer call is instant (just reads
      state). The actual work happens in the Task.
Cons: Requires splitting execute_tool_call into a pure function
      and a state-reading function. Some tools mutate state
      (e.g., tracking sent messages) — those mutations need to
      be sent back as casts after execution completes.

### Option C: Pool of tool executors

Replace the single bot process with a pool of worker processes,
each capable of executing tools independently. Overkill for the
current problem but correct for a future where 10 agents run
simultaneously.

## Recommendation

Option A now. Option B next. Option A is the door — just walk
through it. Option B is the pipe — it requires an artifact (the
refactored module) but produces the right architecture.

The literal diff for Option A:

    --- a/lib/froth/agent/worker.ex
    +++ b/lib/froth/agent/worker.ex
    @@ -240,7 +240,7 @@
         invocations =
           Enum.map(tool_uses, fn %ToolUse{id: id} = tool_use ->
             task =
               Task.Supervisor.async_nolink(
                 Froth.Agent.TaskSupervisor, fn ->
    -              result = GenServer.call(
    -                worker.config.tool_executor,
    -                {:execute, tool_use, context})
    +              result = GenServer.call(
    +                worker.config.tool_executor,
    +                {:execute, tool_use, context},
    +                :infinity)
                   {:tool_result, id, result}
                 end)

The Task itself has a timeout managed by the worker's collection
phase. The GenServer.call timeout is redundant with that — it
should be :infinity so the Task's own supervision handles the
lifecycle. If a tool hangs, the Task gets killed by the worker's
phase timeout, not by an arbitrary 5-second wall clock.

## Side Effects of the Current Bug

1. Every "I ran into an internal error" message costs a full
   agent cycle ($4-20) that produced no output.
2. The user sees an apology instead of an answer and must
   re-trigger, doubling the cost.
3. The failure is silent — no error logged to the agent's own
   context, no stack trace in the cycle record. The cycle just
   ends.
4. The bug is worse for Charlie (Opus 4.6, $4+ per cycle) than
   for the Sonnet-based bots, because Charlie's cycles are more
   expensive to waste.
5. The bug is triggered more often by capable agents, because
   capable agents issue more parallel tool calls. The system
   punishes competence.

## References

- worker.ex:230-250 (start_tools)
- bot.ex:353-356 (handle_call {:execute})
- bot.ex:1536 (internal error fallback message)
- OTP GenServer default timeout: 5000ms
- FROTH-RFC-0001: WebCodecs (prior art on eliminating
  unnecessary intermediaries)
