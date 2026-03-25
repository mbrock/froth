defmodule Froth.Inference.Tools do
  @moduledoc """
  Tool catalog and execution for inference sessions.
  """

  alias Froth.Agent.Adhoc
  alias Froth.{ChatSummary, Event, LLM, Repo}
  alias Froth.Search, as: WebSearch
  alias Froth.Telegram.BotAdapter
  alias Froth.Telemetry.Span
  import Ecto.Query

  @default_session_id "charlie"
  @read_tool_transcript_max_cycles 5
  @read_tool_transcript_max_chars 20_000
  @read_tool_transcript_max_message_lines 120
  @read_tool_transcript_max_task_output_chars 3_000
  @spawn_agent_default_model "gpt-5.4-mini"
  @spawn_agent_default_tool_names ["run_shell", "elixir_eval"]
  @wolfram_mcp_url "https://services.wolfram.com/api/mcp"

  @tool_specs [
    %{
      "name" => "send_message",
      "description" =>
        "Send a text message to the chat. Call this once per paragraph — don't wait until you've composed the entire reply. Stream your response by sending each paragraph or thought as a separate send_message call as you go.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "text" => %{"type" => "string", "description" => "The message text to send."}
        },
        "required" => ["text"],
        "additionalProperties" => false
      }
    },
    %{
      "name" => "read_log",
      "description" =>
        "Read the chronological chat log for a date range. Returns all messages in order. Use to browse what happened on a given day or period.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "from_date" => %{
            "type" => "string",
            "description" =>
              "Start date or datetime, ISO 8601 (e.g. 2026-02-10 or 2026-02-10T14:30:00)."
          },
          "to_date" => %{
            "type" => "string",
            "description" =>
              "End date or datetime, ISO 8601 (e.g. 2026-02-11 or 2026-02-11T08:00:00)."
          },
          "sender_id" => %{"type" => "integer", "description" => "Telegram user ID to filter by."}
        },
        "required" => ["from_date"],
        "additionalProperties" => false
      }
    },
    %{
      "name" => "search",
      "description" =>
        "Search chat history by text. Returns matching messages with surrounding context. Use before/after to control context size (default 3).",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Phrases to search for (case-insensitive, OR'd together). Each item is matched exactly as a phrase."
          },
          "from_date" => %{
            "type" => "string",
            "description" => "Start date or datetime, ISO 8601."
          },
          "to_date" => %{"type" => "string", "description" => "End date or datetime, ISO 8601."},
          "sender_id" => %{"type" => "integer", "description" => "Telegram user ID to filter by."},
          "before" => %{
            "type" => "integer",
            "description" => "Context messages before each hit. Default 3."
          },
          "after" => %{
            "type" => "integer",
            "description" => "Context messages after each hit. Default 3."
          }
        },
        "required" => ["query"],
        "additionalProperties" => false
      }
    },
    %{
      "name" => "web_search",
      "description" =>
        "Research a topic via Grok, OpenAI, and Gemini simultaneously. Returns a triangulated result with source attribution, provider status, and confidence markers. Use this for any factual question that benefits from web sources. The models will dig, think, and report — not just return links.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "The search query. Be specific."
          }
        },
        "required" => ["query"],
        "additionalProperties" => false
      }
    },
    %{
      "name" => "view_analysis",
      "description" =>
        "Read the full analysis text for one or more analysis IDs. Use this when you see an analysis snippet in the chat log and want the complete description (photo analysis, voice transcription, video analysis, etc.).",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "ids" => %{
            "type" => "array",
            "items" => %{"type" => "integer"},
            "description" =>
              "Analysis IDs to read (from the analysis:N references in the chat log)."
          }
        },
        "required" => ["ids"],
        "additionalProperties" => false
      }
    },
    %{
      "name" => "look",
      "description" =>
        "Open a Telegram photo or document by message ID and return native content blocks. " <>
          "For images, returns a text metadata block plus an image block. " <>
          "For PDFs, returns a text metadata block plus a document block.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "message_id" => %{
            "type" => "integer",
            "description" => "Telegram message ID from chat logs (the number from msg:12345)."
          }
        },
        "required" => ["message_id"],
        "additionalProperties" => false
      }
    },
    %{
      "name" => "read_tool_transcript",
      "description" =>
        "Read transcripts from previous agent cycles in this chat, including assistant tool calls, tool results, and linked eval/shell task output.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "cycle_id" => %{
            "type" => "string",
            "description" => "Optional specific cycle ID (ULID)."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "How many recent cycles to include. Default 3."
          },
          "include_messages" => %{
            "type" => "boolean",
            "description" =>
              "Include assistant/user message transcript blocks. Default false (noisy)."
          },
          "include_task_output" => %{
            "type" => "boolean",
            "description" =>
              "Include linked eval/shell task output near each cycle. Default true."
          },
          "task_output_lines" => %{
            "type" => "integer",
            "description" => "Max event lines per task when include_task_output is true."
          }
        },
        "additionalProperties" => false
      }
    },
    %{
      "name" => "elixir_eval",
      "description" =>
        "Evaluate Elixir code on the live Froth node. Returns the inspected result and any IO output. " <>
          "You have full access to Ecto repos (Froth.Repo), GenServers, OTP processes, the whole application. " <>
          "Use `import Ecto.Query` then query telegram_messages, analyses, etc. " <>
          "Variable bindings declared by your code (for example `a = 1`) are saved in the eval session and are visible to later elixir_eval calls that use the same session_id. " <>
          "Useful for checking system state, counting things, running ad-hoc queries, inspecting processes. " <>
          "If execution runs long (~15s), it continues in background and returns a task_id; use list_tasks / task_output / stop_task. " <>
          "Tip: Froth.help(Module) returns docs and signatures for any module.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "code" => %{
            "type" => "string",
            "description" => "Elixir code to evaluate. The last expression's value is returned."
          },
          "session_id" => %{
            "type" => "string",
            "description" =>
              "Optional eval session ID. All variables declared in this session are persisted and visible to later evals with the same session_id. If omitted, a new random session is created."
          },
          "narration" => %{
            "type" => "string",
            "description" =>
              "Optional prose narration of what this code does and why, in Aristotelian practical syllogism format (premise → premise → therefore action). Automatically sent as italics to the chat so observers can follow along."
          }
        },
        "required" => ["code", "narration"],
        "additionalProperties" => false
      }
    },
    %{
      "name" => "run_shell",
      "description" =>
        "Run a shell command (via bash). If the command finishes within ~3 seconds, " <>
          "returns the output directly. Otherwise, returns a task_id for tracking — " <>
          "use list_tasks and task_output to monitor progress. " <>
          "Use for compiling, running scripts, system commands, git, etc.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "Shell command to run."
          },
          "working_dir" => %{
            "type" => "string",
            "description" =>
              "Working directory for the command. Defaults to the Froth project root."
          },
          "narration" => %{
            "type" => "string",
            "description" =>
              "Optional prose narration of what this command does and why, in Aristotelian practical syllogism format. Automatically sent as italics to the chat."
          }
        },
        "required" => ["command", "narration"],
        "additionalProperties" => false
      }
    },
    %{
      "name" => "send_input",
      "description" =>
        "Send stdin input to a running shell task. Use for interactive commands that expect input.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string", "description" => "Task ID (e.g. shell:a3f8c1)."},
          "input" => %{
            "type" => "string",
            "description" => "Text to send to stdin (newline appended automatically)."
          }
        },
        "required" => ["task_id", "input"],
        "additionalProperties" => false
      }
    },
    %{
      "name" => "list_tasks",
      "description" => "List active and recently completed tasks with output rates and status.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => false
      }
    },
    %{
      "name" => "task_output",
      "description" =>
        "Read recent output lines from a task. Useful for checking progress on long-running commands.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string", "description" => "Task ID (e.g. shell:a3f8c1)."},
          "lines" => %{
            "type" => "integer",
            "description" => "Number of recent output lines to return. Default 50."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      }
    },
    %{
      "name" => "stop_task",
      "description" => "Stop a running task. Sends SIGTERM by default, or a specific signal.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string", "description" => "Task ID (e.g. shell:a3f8c1)."},
          "signal" => %{
            "type" => "string",
            "description" => "Signal to send (e.g. TERM, KILL, INT). Default: TERM."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      }
    },
    %{
      "name" => "subscribe_task",
      "description" =>
        "Register interest in a task. The system will automatically send you a message " <>
          "when the task completes (or after expect_minutes if still running). " <>
          "After subscribing, you do NOT need to poll, check, or wait — just stop and " <>
          "move on. You will be woken up with the result when it's ready.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string", "description" => "Task ID to subscribe to."},
          "expect_minutes" => %{
            "type" => "integer",
            "description" =>
              "Expected completion time in minutes. If still running after this, you'll be notified."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      }
    },
    %{
      "name" => "yield",
      "description" =>
        "Pause this cycle and wait for I/O. Call this after subscribing to one or more tasks " <>
          "with subscribe_task. The cycle will end cleanly and you will be woken up " <>
          "when a subscribed task completes. This saves inference cost by not polling. " <>
          "Do NOT call task_output or list_tasks after subscribing — just yield.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "reason" => %{
            "type" => "string",
            "description" => "Optional note about what you're waiting for."
          }
        },
        "additionalProperties" => false
      }
    },
    %{
      "name" => "spawn_engineer",
      "description" =>
        "Dispatch a coding task to Codex, a trusted senior engineer who works in the background. " <>
          "This is the best way to do complex coding work — refactors, migrations, new features, bug fixes. " <>
          "Codex gets NO chat context, so your prompt must be self-contained: explain what we want done, " <>
          "why, and any constraints. Do NOT over-specify implementation details — Codex is a competent " <>
          "engineer who will read the codebase, make good architectural decisions, commit the result, and " <>
          "report back. Codex has excellent web search capabilities built in, so it can find docs, APIs, " <>
          "solutions, and examples on its own — you do not need to look things up for it. " <>
          "Think of it as explaining the problem to a colleague, not dictating line-by-line changes. " <>
          "Good: 'the telemetry live view is too fluffy on mobile; tighten the layout significantly.' " <>
          "Bad: 'change .events-header padding from 1.5rem to 0.25rem in lib/froth/...' " <>
          "Returns a session URL where you can watch progress. The task runs in background — you do not need to wait.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "prompt" => %{
            "type" => "string",
            "description" =>
              "What you want built or fixed. Be clear about the goal, not the implementation. Codex will figure out the how."
          }
        },
        "required" => ["prompt"],
        "additionalProperties" => false
      }
    },
    %{
      "name" => "spawn_agent",
      "description" =>
        "Start an ad-hoc sub-agent in the background and return its cycle ID. " <>
          "Use this to delegate a bounded task to another agent without manually wiring Froth.Agent.Adhoc. " <>
          "By default the sub-agent gets shell and elixir_eval. " <>
          "Check progress or final results later with read_tool_transcript using the returned cycle_id.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "prompt" => %{
            "type" => "string",
            "description" => "Self-contained prompt for the delegated sub-agent."
          },
          "model" => %{
            "type" => "string",
            "description" => "Optional model for the sub-agent. Defaults to gpt-5.4-mini."
          },
          "tools" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Optional tool names to expose to the sub-agent. Defaults to [\"shell\", \"elixir_eval\"]. " <>
                "\"shell\" is an alias for run_shell. Pass [] for a no-tools sub-agent."
          },
          "system_prompt" => %{
            "type" => "string",
            "description" =>
              "Optional system prompt override for the sub-agent. If omitted, the default adhoc system prompt is used."
          }
        },
        "required" => ["prompt"],
        "additionalProperties" => false
      }
    }
  ]

  def specs_for_api do
    @tool_specs ++ remote_mcp_specs()
  end

  def specs_for_names(names) when is_list(names) do
    wanted = MapSet.new(names)
    Enum.filter(specs_for_api(), &MapSet.member?(wanted, &1["name"]))
  end

  defp remote_mcp_specs do
    case LLM.active_api_key("wolfram") do
      token when is_binary(token) and token != "" -> [wolfram_mcp_spec()]
      _ -> []
    end
  end

  defp wolfram_mcp_spec do
    %{
      "type" => "mcp_endpoint",
      "name" => "wolfram",
      "url" => @wolfram_mcp_url,
      "bearer_token_provider" => "wolfram",
      "defer_loading" => true
    }
  end

  def label("read_log"), do: "read chat log"
  def label("search"), do: "search chat log"
  def label("web_search"), do: "research"
  def label("view_analysis"), do: "open analysis"
  def label("look"), do: "look at media"
  def label("read_tool_transcript"), do: "read tool transcript"
  def label("elixir_eval"), do: "run code"
  def label("run_shell"), do: "run shell"
  def label("send_input"), do: "send input"
  def label("list_tasks"), do: "list tasks"
  def label("task_output"), do: "task output"
  def label("stop_task"), do: "stop task"
  def label("subscribe_task"), do: "subscribe"
  def label("yield"), do: "yield"
  def label("spawn_engineer"), do: "spawn engineer"
  def label("spawn_agent"), do: "spawn agent"
  def label(name) when is_binary(name), do: name
  def label(_), do: "tool"

  def execute(name, input, chat_id, opts) do
    session_id = opts[:session_id] || @default_session_id

    case name do
      "read_log" ->
        {:ok, read_log(chat_id, input, session_id)}

      "search" ->
        {:ok, search(chat_id, input, session_id)}

      "web_search" ->
        case input["query"] do
          query when is_binary(query) ->
            with {:ok, result} <- WebSearch.query(query) do
              {:ok, Froth.Search.Result.tool_payload(result)}
            end

          _ ->
            {:error, "query must be a string"}
        end

      "view_analysis" ->
        {:ok, view_analysis(input)}

      "look" ->
        look(chat_id, input, session_id)

      "read_tool_transcript" ->
        bot_id = opts[:bot_id] || "charlie"
        {:ok, read_tool_transcript(chat_id, bot_id, input)}

      "elixir_eval" ->
        topic =
          cond do
            is_binary(opts[:topic]) and opts[:topic] != "" ->
              opts[:topic]

            opts[:ref] ->
              "tool:#{opts[:ref]}"

            true ->
              nil
          end

        requested_eval_session_id = eval_session_id(input)

        eval_opts = [session_id: requested_eval_session_id]
        eval_opts = if topic, do: Keyword.put(eval_opts, :topic, topic), else: eval_opts

        eval_opts =
          if opts[:bot_id] do
            Keyword.put(eval_opts, :telegram, %{bot_id: opts[:bot_id], chat_id: chat_id})
          else
            eval_opts
          end

        Froth.Tasks.Eval.run_eval(input["code"], eval_opts)

      "run_shell" ->
        command = input["command"]

        working_dir =
          case input["working_dir"] do
            dir when is_binary(dir) and dir != "" -> dir
            _ -> File.cwd!()
          end

        shell_opts = [working_dir: working_dir]

        shell_opts =
          if opts[:bot_id] do
            Keyword.put(shell_opts, :telegram, %{
              bot_id: opts[:bot_id],
              chat_id: chat_id
            })
          else
            shell_opts
          end

        Froth.Tasks.Shell.run_shell(command, shell_opts)

      "send_input" ->
        task_id = input["task_id"]
        text = input["input"] <> "\n"

        if Froth.Tasks.Shell.alive?(task_id) do
          Froth.Tasks.Shell.send_input(task_id, text)
          {:ok, "Sent input to #{task_id}."}
        else
          {:error, "Task #{task_id} is not running."}
        end

      "list_tasks" ->
        bot_id = opts[:bot_id] || "charlie"
        tasks = Froth.Tasks.list_recent(bot_id)

        if tasks == [] do
          {:ok, "No tasks."}
        else
          lines =
            Enum.map(tasks, fn t ->
              elapsed = format_task_elapsed(t)
              "[#{t.task_id}] #{t.label || t.type} — #{t.status} #{elapsed}"
            end)

          {:ok, Enum.join(lines, "\n")}
        end

      "task_output" ->
        task_id = input["task_id"]
        limit = input["lines"] || 50
        events = Froth.Tasks.recent_output(task_id, limit)

        if events == [] do
          {:ok, "No output for task #{task_id}."}
        else
          stats = Froth.Tasks.output_stats(task_id)

          header =
            "Task #{task_id} — #{stats.total} lines total, #{Float.round(stats.rate_per_second, 1)} lines/s\n---\n"

          output = Enum.map_join(events, "", & &1.content)
          {:ok, header <> String.slice(output, 0, 8000)}
        end

      "stop_task" ->
        task_id = input["task_id"]
        signal = input["signal"] || "TERM"

        if Froth.Tasks.Shell.alive?(task_id) do
          Froth.Tasks.Shell.send_signal(task_id, signal)
          {:ok, "Sent SIG#{signal} to #{task_id}."}
        else
          cond do
            Froth.Tasks.Eval.alive?(task_id) ->
              Froth.Tasks.Eval.stop_eval(task_id)
              Froth.Tasks.stop(task_id)
              {:ok, "Stopped task #{task_id}."}

            Froth.Tasks.Video.alive?(task_id) ->
              Froth.Tasks.Video.stop_video(task_id)
              Froth.Tasks.stop(task_id)
              {:ok, "Stopped task #{task_id}."}

            true ->
              task = Froth.Tasks.get(task_id)

              if task && task.status in ["pending", "running"] do
                Froth.Tasks.stop(task_id)
                {:ok, "Stopped task #{task_id}."}
              else
                {:error, "Task #{task_id} is not running."}
              end
          end
        end

      "subscribe_task" ->
        task_id = input["task_id"]
        expect_minutes = input["expect_minutes"]
        bot_id = opts[:bot_id] || "charlie"

        task = Froth.Tasks.get(task_id)

        cond do
          task == nil ->
            {:error, "Task #{task_id} not found."}

          task.status in ["completed", "failed", "stopped"] ->
            {:ok, "Task #{task_id} already #{task.status}. No need to subscribe."}

          true ->
            Froth.Tasks.subscribe_telegram(task_id, bot_id, chat_id, expect_minutes)

            msg =
              "Subscribed to #{task_id}. You will receive a message when it completes" <>
                if(expect_minutes, do: " or after #{expect_minutes} minutes", else: "") <>
                ". You can stop now — no need to poll or check. The system will wake you up."

            {:ok, msg}
        end

      "yield" ->
        reason = input["reason"] || "Waiting for subscribed tasks."
        {:yield, reason}

      "spawn_engineer" ->
        case input["prompt"] do
          prompt when is_binary(prompt) and prompt != "" ->
            case Froth.Codex.Task.run(prompt, chat_id: chat_id) do
              {:ok, session_id} ->
                url = Froth.Codex.Task.url(session_id)
                {:ok, "Codex task dispatched. Session: #{session_id}\nWatch progress: #{url}"}

              {:error, reason} ->
                {:error, "Failed to start Codex task: #{inspect(reason)}"}
            end

          _ ->
            {:error, "prompt must be a non-empty string"}
        end

      "spawn_agent" ->
        spawn_agent(input, chat_id, opts)

      "register_headlines" ->
        register_headlines(input, chat_id, session_id, opts)

      _ ->
        {:error, "unknown tool: #{name}"}
    end
  end

  defp spawn_agent(input, chat_id, opts) when is_map(input) and is_integer(chat_id) do
    reply_to = spawn_agent_reply_to(input)

    with {:ok, prompt} <- required_trimmed_string(input, "prompt"),
         {:ok, model} <- optional_trimmed_string(input, "model"),
         {:ok, system_prompt} <- optional_trimmed_string(input, "system_prompt"),
         {:ok, tool_names, tool_specs} <- resolve_spawn_agent_tools(input),
         {:ok, {cycle, _pid}} <-
           start_spawn_agent_cycle(
             prompt,
             tool_specs,
             chat_id,
             opts,
             model: model || @spawn_agent_default_model,
             system_prompt: system_prompt,
             reply_to: reply_to
           ) do
      {:ok, spawn_agent_result(cycle, tool_names, opts)}
    end
  end

  defp spawn_agent(_input, _chat_id, _opts), do: {:error, "spawn_agent requires a valid chat_id"}

  defp start_spawn_agent_cycle(prompt, tool_specs, chat_id, opts, extra_opts)
       when is_binary(prompt) and is_list(tool_specs) and is_integer(chat_id) and is_list(opts) and
              is_list(extra_opts) do
    reply_to = spawn_agent_reply_to(extra_opts, opts)

    adhoc_opts =
      [
        chat_id: chat_id,
        reply_to: reply_to,
        bot_id: opts[:bot_id],
        bot_username: opts[:bot_username],
        session_id: opts[:session_id],
        model: Keyword.fetch!(extra_opts, :model),
        tools: tool_specs
      ]
      |> maybe_put_spawn_agent_opt(:system, Keyword.get(extra_opts, :system_prompt))
      |> maybe_put_spawn_agent_opt(:spam, opts[:spam])

    {cycle, stream} = Adhoc.start(prompt, adhoc_opts)
    maybe_link_spawned_cycle(cycle, chat_id, opts[:bot_id], reply_to)

    case start_spawn_agent_stream(stream) do
      {:ok, pid} -> {:ok, {cycle, pid}}
      {:error, reason} -> {:error, "failed to start sub-agent stream: #{inspect(reason)}"}
    end
  end

  defp start_spawn_agent_stream(stream) do
    runner = fn -> Enum.each(stream, fn _item -> :ok end) end

    case Process.whereis(Froth.Agent.TaskSupervisor) do
      pid when is_pid(pid) ->
        Task.Supervisor.start_child(Froth.Agent.TaskSupervisor, runner)

      _ ->
        {:ok, spawn(runner)}
    end
  end

  defp maybe_link_spawned_cycle(%{id: cycle_id}, chat_id, bot_id, reply_to)
       when is_binary(cycle_id) and is_integer(chat_id) and is_binary(bot_id) do
    alias Froth.Telegram.CycleLink

    Repo.insert!(%CycleLink{
      cycle_id: cycle_id,
      bot_id: bot_id,
      chat_id: chat_id,
      reply_to: reply_to
    })

    :ok
  end

  defp maybe_link_spawned_cycle(_cycle, _chat_id, _bot_id, _reply_to), do: :ok

  defp spawn_agent_result(cycle, tool_names, opts) when is_list(tool_names) do
    %{
      "status" => "started",
      "cycle_id" => cycle.id,
      "model" => cycle.model,
      "tools" => tool_names,
      "check_tool" => "read_tool_transcript",
      "check_input" => %{"cycle_id" => cycle.id, "include_messages" => true},
      "check_hint" =>
        "Call read_tool_transcript with cycle_id=#{cycle.id} and include_messages=true to inspect the delegated agent's transcript and final reply."
    }
    |> maybe_put_spawn_agent_result("open_url", spawn_agent_open_url(opts, cycle.id))
  end

  defp spawn_agent_open_url(opts, cycle_id) when is_binary(cycle_id) do
    bot_id = opts[:bot_id]
    bot_username = opts[:bot_username]

    if is_binary(bot_id) and bot_id != "" and is_binary(bot_username) and bot_username != "" do
      "https://t.me/#{bot_username}/tool?startapp=cycle_#{bot_id}_#{cycle_id}"
    end
  end

  defp spawn_agent_open_url(_opts, _cycle_id), do: nil

  defp maybe_put_spawn_agent_result(map, _key, nil), do: map
  defp maybe_put_spawn_agent_result(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_spawn_agent_opt(keyword, _key, nil), do: keyword
  defp maybe_put_spawn_agent_opt(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp spawn_agent_reply_to(extra_opts, _opts) when is_list(extra_opts) do
    case Keyword.get(extra_opts, :reply_to) do
      reply_to when is_integer(reply_to) -> reply_to
      _ -> nil
    end
  end

  defp spawn_agent_reply_to(input) when is_map(input) do
    case Map.get(input, "reply_to") do
      reply_to when is_integer(reply_to) -> reply_to
      _ -> nil
    end
  end

  defp resolve_spawn_agent_tools(input) when is_map(input) do
    case Map.fetch(input, "tools") do
      :error ->
        resolve_spawn_agent_tool_names(@spawn_agent_default_tool_names)

      {:ok, nil} ->
        resolve_spawn_agent_tool_names(@spawn_agent_default_tool_names)

      {:ok, tools} when is_list(tools) ->
        resolve_spawn_agent_tool_names(tools)

      {:ok, _other} ->
        {:error, "tools must be an array of strings"}
    end
  end

  defp resolve_spawn_agent_tool_names(names) when is_list(names) do
    with {:ok, normalized_names} <- normalize_spawn_agent_tool_names(names) do
      available_specs = Map.new(specs_for_api(), &{&1["name"], &1})

      case Enum.filter(normalized_names, &(not Map.has_key?(available_specs, &1))) do
        [] ->
          {:ok, normalized_names, Enum.map(normalized_names, &Map.fetch!(available_specs, &1))}

        unknown ->
          available =
            available_specs
            |> Map.keys()
            |> Enum.sort()
            |> Enum.join(", ")

          {:error,
           "unknown tool names: #{Enum.join(unknown, ", ")}. Available tools: #{available}"}
      end
    end
  end

  defp normalize_spawn_agent_tool_names(names) when is_list(names) do
    Enum.reduce_while(names, {:ok, {MapSet.new(), []}}, fn
      name, {:ok, {seen, acc}} when is_binary(name) ->
        normalized_name =
          name
          |> String.trim()
          |> canonical_spawn_agent_tool_name()

        cond do
          normalized_name == "" ->
            {:halt, {:error, "tools must be an array of non-empty strings"}}

          MapSet.member?(seen, normalized_name) ->
            {:cont, {:ok, {seen, acc}}}

          true ->
            {:cont, {:ok, {MapSet.put(seen, normalized_name), acc ++ [normalized_name]}}}
        end

      _name, _acc ->
        {:halt, {:error, "tools must be an array of strings"}}
    end)
    |> case do
      {:ok, {_seen, acc}} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_spawn_agent_tool_name("shell"), do: "run_shell"
  defp canonical_spawn_agent_tool_name(name), do: name

  defp required_trimmed_string(input, key) when is_map(input) and is_binary(key) do
    case optional_trimmed_string(input, key) do
      {:ok, nil} -> {:error, "#{key} must be a non-empty string"}
      other -> other
    end
  end

  defp optional_trimmed_string(input, key) when is_map(input) and is_binary(key) do
    case Map.get(input, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        trimmed = String.trim(value)
        {:ok, if(trimmed == "", do: nil, else: trimmed)}

      _value ->
        {:error, "#{key} must be a string"}
    end
  end

  defp register_headlines(%{"date" => date, "headlines" => headlines}, chat_id, session_id, opts)
       when is_binary(date) and is_list(headlines) and is_binary(session_id) and
              is_integer(chat_id) do
    with {:ok, normalized_headlines} <- normalize_headlines(headlines) do
      case maybe_send_headlines_message(date, normalized_headlines, chat_id, session_id, opts) do
        {:ok, _sent} ->
          store_headlines_registered_event(date, chat_id, normalized_headlines)

          Span.execute(
            [:froth, :headlines, :registered],
            nil,
            %{date: date, chat_id: chat_id, headlines: normalized_headlines},
            %{count: length(normalized_headlines)}
          )

          progress = headlines_progress(chat_id, date)

          {:ok,
           "Registered #{length(normalized_headlines)} headlines for #{date}. " <>
             "Progress: #{progress.done_days}/#{progress.total_days} days done. " <>
             next_unfinished_text(progress.next_unfinished)}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp register_headlines(_input, _chat_id, _session_id, _opts) do
    {:error, "register_headlines requires date and headlines"}
  end

  defp maybe_send_headlines_message(date, normalized_headlines, chat_id, session_id, opts)
       when is_binary(date) and is_list(normalized_headlines) and is_integer(chat_id) and
              is_binary(session_id) do
    if Keyword.get(opts, :spam, true) do
      {text, entities} = format_headlines_message(date, normalized_headlines)
      send_message_fun = Keyword.get(opts, :send_message_fun, &BotAdapter.send_message/4)
      reply_markup = headlines_reply_markup(opts)

      send_message_opts =
        [entities: entities]
        |> maybe_put_send_message_opt(:reply_markup, reply_markup)

      send_message_fun.(session_id, chat_id, text, send_message_opts)
    else
      {:ok, :suppressed}
    end
  end

  defp normalize_headlines(headlines) when is_list(headlines) do
    headlines
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {headline, index}, {:ok, acc} ->
      case normalize_headline(headline) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, reason} -> {:halt, {:error, "headline #{index + 1}: #{reason}"}}
      end
    end)
  end

  defp normalize_headline(%{
         "emoji" => emoji,
         "title" => title,
         "sentence" => sentence,
         "from_time" => from_time,
         "to_time" => to_time
       })
       when is_binary(emoji) and is_binary(title) and is_binary(sentence) and
              is_binary(from_time) and is_binary(to_time) do
    normalize_headline_fields(emoji, title, sentence, from_time, to_time)
  end

  defp normalize_headline(%{
         emoji: emoji,
         title: title,
         sentence: sentence,
         from_time: from_time,
         to_time: to_time
       })
       when is_binary(emoji) and is_binary(title) and is_binary(sentence) and
              is_binary(from_time) and is_binary(to_time) do
    normalize_headline_fields(emoji, title, sentence, from_time, to_time)
  end

  defp normalize_headline(_headline),
    do: {:error, "expected emoji, title, sentence, from_time, and to_time strings"}

  defp format_headlines_message(date, headlines) when is_binary(date) and is_list(headlines) do
    separator = "\n\n"

    body =
      headlines
      |> Enum.map_join(separator, &headline_line/1)

    text =
      case body do
        "" -> date
        _ -> date <> "\n\n" <> body
      end

    header_entities = [bold_entity(0, utf16_length(date))]

    entities =
      headlines
      |> Enum.reduce({header_entities, utf16_length(date <> separator)}, fn headline,
                                                                            {acc, offset} ->
        title = headline["title"]
        line = headline_line(headline)
        title_offset = offset + headline_title_offset(headline)
        next_offset = offset + utf16_length(line) + utf16_length(separator)
        {acc ++ [bold_entity(title_offset, utf16_length(title))], next_offset}
      end)
      |> elem(0)

    {text, entities}
  end

  defp store_headlines_registered_event(date, chat_id, headlines)
       when is_binary(date) and is_integer(chat_id) and is_list(headlines) do
    %Event{}
    |> Event.changeset(%{
      event: "froth.headlines.registered",
      metadata: %{
        "date" => date,
        "chat_id" => Integer.to_string(chat_id),
        "headlines" => headlines
      },
      measurements: %{"count" => length(headlines)}
    })
    |> Repo.insert!(log: false)
  end

  defp normalize_headline_fields(emoji, title, sentence, from_time, to_time) do
    with {:ok, normalized_emoji} <- normalize_headline_emoji(emoji),
         {:ok, normalized_from_time, from_datetime} <-
           normalize_iso8601_datetime(from_time, "from_time"),
         {:ok, normalized_to_time, to_datetime} <- normalize_iso8601_datetime(to_time, "to_time"),
         :ok <- validate_headline_time_range(from_datetime, to_datetime) do
      {:ok,
       %{
         "emoji" => normalized_emoji,
         "title" => String.trim(title),
         "sentence" => String.trim(sentence),
         "from_time" => normalized_from_time,
         "to_time" => normalized_to_time
       }}
    end
  end

  defp normalize_headline_emoji(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, "emoji must be a non-empty string"}

      length(String.graphemes(trimmed)) != 1 ->
        {:error, "emoji must be a single emoji"}

      true ->
        {:ok, trimmed}
    end
  end

  defp normalize_iso8601_datetime(value, field_name) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {:error, "#{field_name} must be a non-empty ISO 8601 datetime"}
    else
      case parse_iso8601_datetime(trimmed) do
        {:ok, datetime} -> {:ok, DateTime.to_iso8601(datetime), datetime}
        :error -> {:error, "#{field_name} must be an ISO 8601 datetime"}
      end
    end
  end

  defp parse_iso8601_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive_datetime} -> {:ok, DateTime.from_naive!(naive_datetime, "Etc/UTC")}
          {:error, _reason} -> :error
        end
    end
  end

  defp validate_headline_time_range(from_datetime, to_datetime)
       when is_struct(from_datetime, DateTime) and is_struct(to_datetime, DateTime) do
    case DateTime.compare(from_datetime, to_datetime) do
      :gt -> {:error, "from_time must be before or equal to to_time"}
      _ -> :ok
    end
  end

  defp headline_line(%{
         "emoji" => emoji,
         "title" => title,
         "from_time" => from_time,
         "to_time" => to_time
       }) do
    "#{emoji} #{title} #{headline_time_window(from_time, to_time)}"
  end

  defp headline_title_offset(%{"emoji" => emoji}) when is_binary(emoji),
    do: utf16_length("#{emoji} ")

  defp headline_time_window(from_time, to_time)
       when is_binary(from_time) and is_binary(to_time) do
    {:ok, from_datetime} = parse_iso8601_datetime(from_time)
    {:ok, to_datetime} = parse_iso8601_datetime(to_time)

    "(" <>
      Calendar.strftime(from_datetime, "%H:%M") <>
      "-" <> Calendar.strftime(to_datetime, "%H:%M") <> " UTC)"
  end

  defp utf16_length(text) when is_binary(text) do
    text
    |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
    |> byte_size()
    |> div(2)
  end

  defp headlines_progress(chat_id, current_date)
       when is_integer(chat_id) and is_binary(current_date) do
    summary_dates = available_summary_dates(chat_id)

    registered_dates =
      chat_id
      |> registered_headline_dates()
      |> Enum.reduce(MapSet.new(), &MapSet.put(&2, &1))
      |> MapSet.put(current_date)

    %{
      done_days: MapSet.size(registered_dates),
      total_days: length(summary_dates),
      next_unfinished:
        Enum.find(summary_dates, fn date -> not MapSet.member?(registered_dates, date) end)
    }
  end

  defp available_summary_dates(chat_id) when is_integer(chat_id) do
    Repo.all(
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id,
        distinct: fragment("timezone('UTC', to_timestamp(?))::date", s.from_date),
        order_by: fragment("timezone('UTC', to_timestamp(?))::date", s.from_date),
        select: fragment("timezone('UTC', to_timestamp(?))::date", s.from_date)
      ),
      log: false
    )
    |> Enum.map(&Date.to_iso8601/1)
  end

  defp registered_headline_dates(chat_id) when is_integer(chat_id) do
    chat_id_string = Integer.to_string(chat_id)

    Repo.all(
      from(e in Event,
        where:
          e.event == "froth.headlines.registered" and
            fragment("?->>'chat_id' = ?", e.metadata, ^chat_id_string),
        distinct: fragment("?->>'date'", e.metadata),
        order_by: fragment("?->>'date'", e.metadata),
        select: fragment("?->>'date'", e.metadata)
      ),
      log: false
    )
  end

  defp next_unfinished_text(nil), do: "Next unfinished: none."
  defp next_unfinished_text(date), do: "Next unfinished: #{date}."

  defp maybe_put_send_message_opt(keyword, _key, nil), do: keyword
  defp maybe_put_send_message_opt(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp headlines_reply_markup(opts) when is_list(opts) do
    cycle_id = opts[:cycle_id]
    bot_id = opts[:bot_id]
    bot_username = opts[:bot_username]

    if is_binary(cycle_id) and cycle_id != "" and is_binary(bot_id) and bot_id != "" and
         is_binary(bot_username) and bot_username != "" do
      %{
        "@type" => "replyMarkupInlineKeyboard",
        "rows" => [
          [
            %{
              "@type" => "inlineKeyboardButton",
              "text" => "Open",
              "type" => %{
                "@type" => "inlineKeyboardButtonTypeUrl",
                "url" => "https://t.me/#{bot_username}/tool?startapp=cycle_#{bot_id}_#{cycle_id}"
              }
            }
          ]
        ]
      }
    end
  end

  defp headlines_reply_markup(_opts), do: nil

  defp bold_entity(offset, length) when is_integer(offset) and is_integer(length) do
    %{
      "@type" => "textEntity",
      "offset" => offset,
      "length" => length,
      "type" => %{"@type" => "textEntityTypeBold"}
    }
  end

  defp format_task_elapsed(%{started_at: nil}), do: ""

  defp format_task_elapsed(%{finished_at: finished_at, started_at: started_at})
       when not is_nil(finished_at) do
    seconds = DateTime.diff(finished_at, started_at, :second)
    "(#{format_duration(seconds)})"
  end

  defp format_task_elapsed(%{started_at: started_at}) do
    seconds = DateTime.diff(DateTime.utc_now(), started_at, :second)
    "(#{format_duration(seconds)})"
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) when seconds < 3600,
    do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

  defp format_duration(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  defp read_log(chat_id, input, session_id) do
    base =
      from(m in "telegram_messages",
        where: m.chat_id == ^chat_id,
        select: %{date: m.date, sender_id: m.sender_id, message_id: m.message_id, raw: m.raw}
      )

    base =
      case parse_datetime(input["from_date"]) do
        nil -> base
        unix -> from(m in base, where: m.date >= ^unix)
      end

    base =
      case parse_to_datetime(input["to_date"]) do
        nil -> base
        unix -> from(m in base, where: m.date < ^unix)
      end

    base =
      case input["sender_id"] do
        sid when is_integer(sid) -> from(m in base, where: m.sender_id == ^sid)
        _ -> base
      end

    msgs =
      Repo.all(from(m in base, order_by: [asc: m.date], limit: 200), log: false)
      |> Enum.uniq_by(& &1.message_id)

    if msgs == [] do
      "No messages found in the given range."
    else
      analyses_map = fetch_analyses(chat_id, Enum.map(msgs, & &1.message_id))
      Enum.map_join(msgs, "\n", &format_msg(&1, analyses_map, session_id))
    end
  end

  defp search(chat_id, input, session_id) do
    queries = input["query"] || []
    ctx_before = input["before"] || 3
    ctx_after = input["after"] || 3

    base =
      from(m in "telegram_messages",
        where: m.chat_id == ^chat_id,
        select: %{date: m.date, sender_id: m.sender_id, message_id: m.message_id, raw: m.raw}
      )

    patterns = Enum.map(queries, &"%#{&1}%")

    base =
      from(m in base,
        where:
          fragment(
            "coalesce(raw->'content'->'text'->>'text', raw->'content'->'caption'->>'text', '') ILIKE ANY(?)",
            ^patterns
          )
      )

    base =
      case parse_datetime(input["from_date"]) do
        nil -> base
        unix -> from(m in base, where: m.date >= ^unix)
      end

    base =
      case parse_to_datetime(input["to_date"]) do
        nil -> base
        unix -> from(m in base, where: m.date < ^unix)
      end

    base =
      case input["sender_id"] do
        sid when is_integer(sid) -> from(m in base, where: m.sender_id == ^sid)
        _ -> base
      end

    hits =
      Repo.all(from(m in base, order_by: [desc: m.date], limit: 10), log: false)
      |> Enum.uniq_by(& &1.message_id)
      |> Enum.take(8)

    if hits == [] do
      "No messages found matching #{inspect(queries)}."
    else
      hit_groups =
        Enum.map(hits, fn hit ->
          before =
            Repo.all(
              from(m in "telegram_messages",
                where: m.chat_id == ^chat_id and m.date < ^hit.date,
                order_by: [desc: m.date],
                limit: ^ctx_before,
                select: %{
                  date: m.date,
                  sender_id: m.sender_id,
                  message_id: m.message_id,
                  raw: m.raw
                }
              ),
              log: false
            )
            |> Enum.reverse()

          after_msgs =
            Repo.all(
              from(m in "telegram_messages",
                where: m.chat_id == ^chat_id and m.date > ^hit.date,
                order_by: [asc: m.date],
                limit: ^ctx_after,
                select: %{
                  date: m.date,
                  sender_id: m.sender_id,
                  message_id: m.message_id,
                  raw: m.raw
                }
              ),
              log: false
            )

          {hit, (before ++ [hit] ++ after_msgs) |> Enum.uniq_by(& &1.message_id)}
        end)

      all_msg_ids =
        hit_groups
        |> Enum.flat_map(fn {_, msgs} -> Enum.map(msgs, & &1.message_id) end)
        |> Enum.uniq()

      analyses_map = fetch_analyses(chat_id, all_msg_ids)

      hit_groups
      |> Enum.map(fn {hit, msgs} ->
        Enum.map(msgs, fn m ->
          marker = if m.message_id == hit.message_id, do: ">>> ", else: "    "
          marker <> format_msg(m, analyses_map, session_id)
        end)
        |> Enum.join("\n")
      end)
      |> Enum.join("\n\n---\n\n")
    end
  end

  defp format_msg(msg, analyses_map, session_id) do
    time = DateTime.from_unix!(msg.date) |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
    name = resolve_user(msg.sender_id, session_id)

    text =
      get_in(msg.raw, ["content", "text", "text"]) ||
        get_in(msg.raw, ["content", "caption", "text"]) || ""

    type = get_in(msg.raw, ["content", "@type"]) || "unknown"

    media =
      case type do
        "messageText" -> ""
        "messagePhoto" -> "[photo] "
        "messageVideo" -> "[video] "
        "messageVoiceNote" -> "[voice] "
        "messageDocument" -> "[file] "
        "messageSticker" -> "[sticker] "
        other -> "[#{String.replace(other, "message", "")}] "
      end

    line = "[#{time}] msg:#{msg.message_id} #{name}: #{media}#{text}"

    case Map.get(analyses_map, msg.message_id) do
      nil ->
        line

      [] ->
        line

      analyses ->
        snippets =
          Enum.map_join(analyses, "\n", fn a ->
            snippet =
              a.analysis_text
              |> String.slice(0, 150)
              |> String.replace(~r/\s+/, " ")
              |> String.trim()

            "  → analysis:#{a.id} (#{a.type}): #{snippet}…"
          end)

        line <> "\n" <> snippets
    end
  end

  defp fetch_analyses(_chat_id, []), do: %{}

  defp fetch_analyses(chat_id, message_ids) do
    Repo.all(
      from(a in Froth.Analysis,
        where: a.chat_id == ^chat_id and a.message_id in ^message_ids,
        select: %{
          id: a.id,
          type: a.type,
          message_id: a.message_id,
          analysis_text: a.analysis_text
        }
      ),
      log: false
    )
    |> Enum.group_by(& &1.message_id)
  end

  defp view_analysis(input) do
    ids = input["ids"] || []

    analyses =
      Repo.all(
        from(a in Froth.Analysis,
          where: a.id in ^ids,
          select: %{
            id: a.id,
            type: a.type,
            message_id: a.message_id,
            agent: a.agent,
            analysis_text: a.analysis_text
          }
        ),
        log: false
      )

    if analyses == [] do
      "No analyses found for the given IDs."
    else
      Enum.map_join(analyses, "\n\n---\n\n", fn a ->
        "Analysis ##{a.id} (#{a.type}, msg:#{a.message_id}, by #{a.agent}):\n#{a.analysis_text}"
      end)
    end
  end

  defp look(chat_id, input, session_id)
       when is_integer(chat_id) and is_map(input) and is_binary(session_id) do
    with {:ok, message_id} <- parse_message_reference(input["message_id"]),
         {:ok, message} <- fetch_message_for_look(session_id, chat_id, message_id),
         {:ok, media} <- extract_look_media(message, message_id),
         {:ok, file_data, local_path} <- download_tdlib_file(session_id, media.file_id),
         {:ok, media_type} <- resolve_look_media_type(media, local_path),
         {:ok, content_block} <- look_content_block(media.kind, media_type, file_data) do
      metadata_text = look_metadata_text(media, media_type, byte_size(file_data))

      {:ok, [%{"type" => "text", "text" => metadata_text}, content_block]}
    end
  end

  defp look(_chat_id, _input, _session_id),
    do: {:error, "Could not open media for the given input."}

  defp parse_message_reference(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_message_reference(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.replace_prefix("msg:", "")

    case Integer.parse(normalized) do
      {message_id, ""} when message_id > 0 ->
        {:ok, message_id}

      _ ->
        {:error, "Invalid message_id. Use an integer like 12345 or msg:12345."}
    end
  end

  defp parse_message_reference(_),
    do: {:error, "Invalid message_id. Use an integer like 12345 or msg:12345."}

  defp fetch_message_for_look(session_id, chat_id, message_id)
       when is_binary(session_id) and is_integer(chat_id) and is_integer(message_id) do
    case Froth.Telegram.call(
           session_id,
           %{
             "@type" => "getMessage",
             "chat_id" => chat_id,
             "message_id" => message_id
           },
           60_000
         ) do
      {:ok, %{"@type" => "error", "message" => reason}} ->
        {:error, "getMessage: #{reason}"}

      {:ok, message} when is_map(message) ->
        {:ok, message}

      {:error, reason} ->
        {:error, "getMessage failed: #{inspect(reason)}"}

      other ->
        {:error, "getMessage returned unexpected response: #{inspect(other)}"}
    end
  end

  defp extract_look_media(%{"content" => %{"@type" => "messagePhoto"} = content}, message_id) do
    sizes = get_in(content, ["photo", "sizes"]) || []
    largest = Enum.max_by(sizes, &photo_size_pixels/1, fn -> nil end)
    file_id = get_in(largest || %{}, ["photo", "id"])

    if valid_file_id?(file_id) do
      {:ok,
       %{
         message_id: message_id,
         message_type: "messagePhoto",
         kind: :image,
         file_id: file_id,
         filename: nil,
         caption: caption_text(content),
         declared_media_type: nil
       }}
    else
      {:error, "Message msg:#{message_id} does not include a downloadable photo."}
    end
  end

  defp extract_look_media(
         %{"content" => %{"@type" => "messageDocument", "document" => document} = content},
         message_id
       )
       when is_map(document) do
    file_id = get_in(document, ["document", "id"])
    filename = document["file_name"] || "document"

    declared_media_type =
      document["mime_type"] ||
        media_type_from_filename(filename) ||
        "application/octet-stream"

    kind =
      cond do
        declared_media_type == "application/pdf" -> :pdf
        String.starts_with?(declared_media_type, "image/") -> :image
        true -> :unsupported
      end

    cond do
      not valid_file_id?(file_id) ->
        {:error, "Message msg:#{message_id} does not include a downloadable document."}

      kind == :unsupported ->
        {:error,
         "Message msg:#{message_id} is a #{inspect(declared_media_type)} document. " <>
           "look supports images and PDFs only."}

      true ->
        {:ok,
         %{
           message_id: message_id,
           message_type: "messageDocument",
           kind: kind,
           file_id: file_id,
           filename: filename,
           caption: caption_text(content),
           declared_media_type: declared_media_type
         }}
    end
  end

  defp extract_look_media(_message, message_id) do
    {:error, "Message msg:#{message_id} is not a photo or supported document (image/PDF)."}
  end

  defp photo_size_pixels(size) when is_map(size) do
    (size["width"] || 0) * (size["height"] || 0)
  end

  defp photo_size_pixels(_), do: 0

  defp valid_file_id?(file_id) when is_integer(file_id), do: file_id > 0
  defp valid_file_id?(_), do: false

  defp caption_text(content) when is_map(content) do
    get_in(content, ["caption", "text"]) || ""
  end

  defp caption_text(_), do: ""

  defp download_tdlib_file(session_id, file_id)
       when is_binary(session_id) and is_integer(file_id) do
    case Froth.Telegram.call(
           session_id,
           %{
             "@type" => "downloadFile",
             "file_id" => file_id,
             "priority" => 32,
             "synchronous" => true
           },
           180_000
         ) do
      {:ok, %{"local" => %{"path" => path}}} when is_binary(path) and path != "" ->
        case File.read(path) do
          {:ok, data} ->
            {:ok, data, path}

          {:error, reason} ->
            {:error, "downloaded file read failed: #{inspect(reason)}"}
        end

      {:ok, %{"@type" => "error", "message" => reason}} ->
        {:error, "downloadFile: #{reason}"}

      {:error, reason} ->
        {:error, "downloadFile failed: #{inspect(reason)}"}

      {:ok, other} ->
        {:error, "downloadFile returned unexpected response: #{inspect(other)}"}
    end
  end

  defp download_tdlib_file(_session_id, _file_id),
    do: {:error, "Message does not include a valid downloadable file ID."}

  defp resolve_look_media_type(%{kind: :pdf}, _local_path), do: {:ok, "application/pdf"}

  defp resolve_look_media_type(
         %{kind: :image, declared_media_type: declared_media_type},
         local_path
       ) do
    media_type =
      cond do
        is_binary(declared_media_type) and String.starts_with?(declared_media_type, "image/") ->
          declared_media_type

        true ->
          image_media_type_from_path(local_path)
      end

    {:ok, media_type}
  end

  defp resolve_look_media_type(_media, _local_path),
    do: {:error, "Could not determine media type for this message."}

  defp look_content_block(:image, media_type, file_data)
       when is_binary(media_type) and is_binary(file_data) do
    {:ok,
     %{
       "type" => "image",
       "source" => %{
         "type" => "base64",
         "media_type" => media_type,
         "data" => Base.encode64(file_data)
       }
     }}
  end

  defp look_content_block(:pdf, _media_type, file_data) when is_binary(file_data) do
    {:ok,
     %{
       "type" => "document",
       "source" => %{
         "type" => "base64",
         "media_type" => "application/pdf",
         "data" => Base.encode64(file_data)
       }
     }}
  end

  defp look_content_block(_kind, _media_type, _file_data),
    do: {:error, "Unsupported media type for look tool."}

  defp look_metadata_text(media, media_type, size_bytes) when is_map(media) do
    base_lines = [
      "Loaded msg:#{media.message_id} (#{media.message_type}).",
      "kind: #{if(media.kind == :pdf, do: "pdf", else: "image")}",
      "media_type: #{media_type}",
      "size_bytes: #{size_bytes}"
    ]

    filename_line =
      if is_binary(media.filename) and media.filename != "" do
        "filename: #{media.filename}"
      else
        nil
      end

    caption_line =
      case String.trim(media.caption || "") do
        "" -> nil
        caption -> "caption: #{String.slice(caption, 0, 300)}"
      end

    (base_lines ++ [filename_line, caption_line])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp media_type_from_filename(filename) when is_binary(filename) do
    case filename |> String.downcase() |> Path.extname() do
      ".pdf" -> "application/pdf"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      ".bmp" -> "image/bmp"
      ".tif" -> "image/tiff"
      ".tiff" -> "image/tiff"
      ".heic" -> "image/heic"
      ".heif" -> "image/heif"
      _ -> nil
    end
  end

  defp media_type_from_filename(_), do: nil

  defp image_media_type_from_path(path) when is_binary(path) do
    case path |> String.downcase() |> Path.extname() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      ".bmp" -> "image/bmp"
      ".tif" -> "image/tiff"
      ".tiff" -> "image/tiff"
      ".heic" -> "image/heic"
      ".heif" -> "image/heif"
      _ -> "image/jpeg"
    end
  end

  defp image_media_type_from_path(_), do: "image/jpeg"

  defp read_tool_transcript(chat_id, bot_id, input)
       when is_integer(chat_id) and is_binary(bot_id) and is_map(input) do
    requested_cycle_id = input["cycle_id"]
    cycle_limit = bounded_integer(input["limit"], 3, 1, @read_tool_transcript_max_cycles)
    include_messages = parse_boolean(input["include_messages"], false)
    include_task_output = parse_boolean(input["include_task_output"], true)
    task_output_lines = bounded_integer(input["task_output_lines"], 80, 10, 400)

    alias Froth.Agent
    alias Froth.Agent.{Cycle, Message}
    alias Froth.Telegram.CycleLink

    cycles_query =
      from(l in CycleLink,
        join: c in Cycle,
        on: c.id == l.cycle_id,
        where: l.bot_id == ^bot_id and l.chat_id == ^chat_id,
        order_by: [desc: c.inserted_at]
      )

    cycles_query =
      if is_binary(requested_cycle_id) and requested_cycle_id != "" do
        from([l, c] in cycles_query, where: l.cycle_id == ^requested_cycle_id, limit: 1)
      else
        from([l, c] in cycles_query, limit: ^cycle_limit)
      end

    links =
      Repo.all(
        from([l, c] in cycles_query,
          select: %{
            cycle_id: l.cycle_id,
            reply_to: l.reply_to,
            inserted_at: c.inserted_at,
            updated_at: c.updated_at
          }
        ),
        log: false
      )

    if links == [] do
      if is_binary(requested_cycle_id) and requested_cycle_id != "" do
        "No cycle found for id=#{requested_cycle_id} in this chat."
      else
        "No prior agent cycles found for this chat."
      end
    else
      sections =
        Enum.map(links, fn link ->
          head_id = Agent.latest_head_id(%Cycle{id: link.cycle_id})
          api_messages = Agent.load_messages(head_id) |> Enum.map(&Message.to_api/1)

          format_cycle_transcript(
            link,
            api_messages,
            chat_id,
            bot_id,
            include_messages: include_messages,
            include_task_output: include_task_output,
            task_output_lines: task_output_lines
          )
        end)

      transcript = """
      Agent cycle transcript history for chat #{chat_id} (bot #{bot_id}):

      #{Enum.join(sections, "\n\n---\n\n")}
      """

      transcript
      |> String.trim()
      |> truncate_read_tool_transcript()
    end
  end

  defp read_tool_transcript(_chat_id, _bot_id, _input) do
    "Could not read tool transcript for the given input."
  end

  defp format_cycle_transcript(link, api_messages, chat_id, bot_id, opts)
       when is_map(link) and is_list(api_messages) and is_integer(chat_id) and is_binary(bot_id) do
    include_messages = Keyword.get(opts, :include_messages, true)
    include_task_output = Keyword.get(opts, :include_task_output, true)
    task_output_lines = Keyword.get(opts, :task_output_lines, 120)

    header = """
    cycle #{link.cycle_id}
    created: #{format_datetime(link.inserted_at)}
    reply_to: #{link.reply_to || "n/a"}
    messages: #{length(api_messages)}
    """

    messages_section =
      if include_messages do
        """
        Messages:
        #{format_api_messages_transcript(api_messages)}
        """
      else
        ""
      end

    tasks =
      tasks_for_cycle_window(
        link,
        chat_id,
        bot_id
      )

    tasks_section = """
    Linked tasks:
    #{format_task_transcript(tasks, include_task_output, task_output_lines)}
    """

    [header, messages_section, tasks_section]
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n\n")
    |> String.trim()
  end

  defp format_api_messages_transcript(messages) when is_list(messages) do
    lines =
      messages
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {message, index} ->
        format_api_message_line(message, index)
      end)
      |> Enum.take(@read_tool_transcript_max_message_lines)

    if lines == [] do
      "  (none)"
    else
      Enum.map_join(lines, "\n", &("  " <> &1))
    end
  end

  defp format_api_messages_transcript(_), do: "  (none)"

  defp format_api_message_line(%{"role" => role, "content" => content}, index)
       when is_binary(role) do
    header = "[#{index}] #{role}"

    block_lines =
      cond do
        is_binary(content) ->
          [format_role_content_line(role, content)]

        is_list(content) ->
          Enum.map(content, &format_role_block(role, &1))

        true ->
          [preview_text(inspect(content, limit: 100, printable_limit: 4000), 500)]
      end
      |> Enum.reject(&(is_binary(&1) and String.trim(&1) == ""))
      |> Enum.map(&("    - " <> &1))

    if block_lines == [] do
      [header]
    else
      [header | block_lines]
    end
  end

  defp format_api_message_line(_message, index), do: ["[#{index}] (unrecognized message)"]

  defp format_role_content_line("user", content) when is_binary(content) do
    trimmed = String.trim(content)

    cond do
      trimmed == "" ->
        "(empty)"

      String.contains?(trimmed, "<new_messages>") ->
        "(prompt/context omitted; #{String.length(trimmed)} chars)"

      true ->
        preview_text(trimmed, 700)
    end
  end

  defp format_role_content_line(_role, content) when is_binary(content) do
    preview_text(content, 700)
  end

  defp format_role_block("assistant", %{
         "type" => "tool_use",
         "name" => name,
         "id" => id,
         "input" => input
       }) do
    "tool_use #{name} id=#{id} input=#{preview_json(input, 700)}"
  end

  defp format_role_block(
         "assistant",
         %{
           "type" => "mcp_tool_use",
           "name" => name,
           "id" => id,
           "input" => input
         } = block
       ) do
    prefix =
      case block["server_name"] do
        server_name when is_binary(server_name) and server_name != "" -> "#{server_name}/"
        _ -> ""
      end

    "mcp_tool_use #{prefix}#{name} id=#{id} input=#{preview_json(input, 700)}"
  end

  defp format_role_block("assistant", %{"type" => "text", "text" => text}) when is_binary(text) do
    "text #{preview_text(text, 700)}"
  end

  defp format_role_block("assistant", %{"type" => "thinking", "thinking" => thinking})
       when is_binary(thinking) do
    "thinking #{preview_text(thinking, 700)}"
  end

  defp format_role_block(
         "user",
         %{
           "type" => "tool_result",
           "tool_use_id" => tool_use_id,
           "content" => content
         } = block
       ) do
    error_label = if block["is_error"] == true, do: " error=true", else: ""

    "tool_result id=#{tool_use_id}#{error_label} #{preview_text(normalize_tool_result(content), 700)}"
  end

  defp format_role_block(
         _role,
         %{
           "type" => "mcp_tool_result",
           "tool_use_id" => tool_use_id,
           "content" => content
         } = block
       ) do
    error_label = if block["is_error"] == true, do: " error=true", else: ""

    "mcp_tool_result id=#{tool_use_id}#{error_label} #{preview_text(normalize_tool_result(content), 700)}"
  end

  defp format_role_block("user", %{"type" => "text", "text" => text}) when is_binary(text) do
    preview_text(text, 700)
  end

  defp format_role_block(_role, block) when is_map(block) do
    preview_json(block, 700)
  end

  defp format_role_block(_role, other), do: preview_text(inspect(other, limit: 50), 700)

  defp tasks_for_cycle_window(
         %{inserted_at: inserted_at, updated_at: updated_at},
         chat_id,
         bot_id
       )
       when is_integer(chat_id) and is_binary(bot_id) do
    {window_from, window_to} = task_window(inserted_at, updated_at)

    Repo.all(
      from(t in Froth.Task,
        join: l in Froth.TaskTelegramLink,
        on: l.task_id == t.task_id,
        where:
          l.bot_id == ^bot_id and l.chat_id == ^chat_id and t.type in ["eval", "shell", "video"] and
            t.inserted_at >= ^window_from and t.inserted_at <= ^window_to,
        order_by: [asc: t.inserted_at],
        distinct: t.task_id
      ),
      log: false
    )
  end

  defp tasks_for_cycle_window(_, _chat_id, _bot_id), do: []

  defp format_task_transcript(tasks, include_task_output, task_output_lines)
       when is_list(tasks) and is_boolean(include_task_output) and is_integer(task_output_lines) do
    if tasks == [] do
      "  (none)"
    else
      Enum.map_join(tasks, "\n", fn task ->
        task_header =
          "  [#{task.task_id}] type=#{task.type} status=#{task.status} inserted_at=#{format_datetime(task.inserted_at)}"

        session_id_label =
          case task.metadata do
            %{"session_id" => eval_session_id}
            when is_binary(eval_session_id) and eval_session_id != "" ->
              "\n    eval_session_id=#{eval_session_id}"

            %{:session_id => eval_session_id}
            when is_binary(eval_session_id) and eval_session_id != "" ->
              "\n    eval_session_id=#{eval_session_id}"

            _ ->
              ""
          end

        label_line =
          if is_binary(task.label) and String.trim(task.label) != "" do
            "\n    label=#{preview_text(task.label, 240)}"
          else
            ""
          end

        output_block =
          if include_task_output do
            task_output_block(task.task_id, task_output_lines)
          else
            ""
          end

        task_header <> session_id_label <> label_line <> output_block
      end)
    end
  end

  defp format_task_transcript(_tasks, _include_task_output, _task_output_lines), do: "  (none)"

  defp task_output_block(task_id, task_output_lines)
       when is_binary(task_id) and is_integer(task_output_lines) do
    events =
      Repo.all(
        from(e in Froth.TaskEvent,
          where: e.task_id == ^task_id,
          order_by: [desc: e.sequence],
          limit: ^task_output_lines
        ),
        log: false
      )
      |> Enum.reverse()

    if events == [] do
      "\n    output: (none)"
    else
      stdout =
        events
        |> Enum.filter(&(&1.kind in ["stdout", "stderr"]))
        |> Enum.map(& &1.content)
        |> IO.iodata_to_binary()
        |> String.trim()

      status_lines =
        events
        |> Enum.filter(&(&1.kind in ["status", "signal", "stdin"]))
        |> Enum.map(fn event ->
          "      [#{event.sequence}] #{event.kind}: #{preview_text(event.content, 220)}"
        end)

      status_block =
        if status_lines == [] do
          ""
        else
          "\n    events:\n" <> Enum.join(status_lines, "\n")
        end

      output_block =
        if stdout == "" do
          "\n    output: (no stdout/stderr in selected event window)"
        else
          "\n    output:\n" <>
            indent_block(
              preview_multiline_text(stdout, @read_tool_transcript_max_task_output_chars),
              "      "
            )
        end

      output_block <> status_block
    end
  end

  defp task_output_block(_task_id, _task_output_lines), do: ""

  defp task_window(inserted_at, updated_at) do
    now = DateTime.utc_now()
    inserted_dt = to_utc_datetime(inserted_at) || now
    updated_dt = to_utc_datetime(updated_at) || inserted_dt

    {
      DateTime.add(inserted_dt, -60, :second),
      DateTime.add(updated_dt, 1_800, :second)
    }
  end

  defp to_utc_datetime(%DateTime{} = dt), do: dt

  defp to_utc_datetime(%NaiveDateTime{} = ndt) do
    case DateTime.from_naive(ndt, "Etc/UTC") do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp to_utc_datetime(_), do: nil

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_datetime(%NaiveDateTime{} = ndt) do
    ndt
    |> NaiveDateTime.to_string()
    |> Kernel.<>(" UTC")
  end

  defp format_datetime(nil), do: "n/a"
  defp format_datetime(other), do: to_string(other)

  defp normalize_tool_result(content) when is_binary(content), do: content

  defp normalize_tool_result(content) when is_list(content) do
    Enum.map_join(content, "\n", &normalize_tool_result_block/1)
  end

  defp normalize_tool_result(content), do: inspect(content, limit: 50, printable_limit: 2000)

  defp normalize_tool_result_block(%{"type" => "text", "text" => text}) when is_binary(text),
    do: text

  defp normalize_tool_result_block(%{"type" => "image", "source" => source}) when is_map(source),
    do: "[image #{source["media_type"] || "unknown"}]"

  defp normalize_tool_result_block(%{"type" => "document", "source" => source})
       when is_map(source),
       do: "[document #{source["media_type"] || "unknown"}]"

  defp normalize_tool_result_block(%{"text" => text}) when is_binary(text), do: text
  defp normalize_tool_result_block(%{"type" => type}) when is_binary(type), do: "[#{type}]"

  defp normalize_tool_result_block(item),
    do: inspect(item, limit: 20, printable_limit: 300)

  defp preview_json(value, max_chars) when is_integer(max_chars) and max_chars > 0 do
    case Jason.encode(value) do
      {:ok, json} -> preview_text(json, max_chars)
      _ -> preview_text(inspect(value, limit: 100, printable_limit: max_chars * 3), max_chars)
    end
  end

  defp preview_text(text, max_chars)
       when is_binary(text) and is_integer(max_chars) and max_chars > 0 do
    compact = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(compact) <= max_chars do
      compact
    else
      String.slice(compact, 0, max_chars) <> "..."
    end
  end

  defp preview_text(text, _max_chars) when is_binary(text), do: String.trim(text)
  defp preview_text(other, _max_chars), do: inspect(other, limit: 50)

  defp preview_multiline_text(text, max_chars)
       when is_binary(text) and is_integer(max_chars) and max_chars > 0 do
    trimmed = String.trim(text)

    if String.length(trimmed) <= max_chars do
      trimmed
    else
      String.slice(trimmed, 0, max_chars) <> "\n..."
    end
  end

  defp preview_multiline_text(text, _max_chars) when is_binary(text), do: String.trim(text)
  defp preview_multiline_text(other, _max_chars), do: inspect(other, limit: 50)

  defp indent_block(text, prefix) when is_binary(text) and is_binary(prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &(prefix <> &1))
  end

  defp truncate_read_tool_transcript(text) when is_binary(text) do
    if String.length(text) > @read_tool_transcript_max_chars do
      String.slice(text, 0, @read_tool_transcript_max_chars) <>
        "\n\n(truncated; narrow with cycle_id or lower limits before asking for more)"
    else
      text
    end
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_), do: nil

  defp bounded_integer(value, default, lower_bound, upper_bound)
       when is_integer(default) and is_integer(lower_bound) and is_integer(upper_bound) do
    parsed = parse_positive_integer(value) || default
    parsed |> max(lower_bound) |> min(upper_bound)
  end

  defp parse_boolean(value, default) when is_boolean(default) do
    cond do
      is_boolean(value) ->
        value

      is_binary(value) ->
        normalized = value |> String.trim() |> String.downcase()

        case normalized do
          "true" -> true
          "1" -> true
          "yes" -> true
          "on" -> true
          "false" -> false
          "0" -> false
          "no" -> false
          "off" -> false
          _ -> default
        end

      true ->
        default
    end
  end

  defp resolve_user(nil, _session_id), do: "unknown"

  defp resolve_user(id, session_id) do
    case Process.get({:user_cache, id}) do
      nil ->
        name =
          case Froth.Telegram.call(session_id, %{"@type" => "getUser", "user_id" => id}) do
            {:ok, %{"first_name" => f, "usernames" => %{"active_usernames" => [u | _]}}} ->
              "#{f} (@#{u})"

            {:ok, %{"first_name" => f}} ->
              f

            _ ->
              "user:#{id}"
          end

        Process.put({:user_cache, id}, name)
        name

      name ->
        name
    end
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} ->
        DateTime.to_unix(dt)

      _ ->
        case NaiveDateTime.from_iso8601(str) do
          {:ok, ndt} ->
            ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

          _ ->
            case Date.from_iso8601(str) do
              {:ok, date} -> date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
              _ -> nil
            end
        end
    end
  end

  defp parse_to_datetime(nil), do: nil
  defp parse_to_datetime(""), do: nil

  defp parse_to_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, _, _} ->
        parse_datetime(str)

      _ ->
        case NaiveDateTime.from_iso8601(str) do
          {:ok, _} ->
            parse_datetime(str)

          _ ->
            case parse_datetime(str) do
              nil -> nil
              unix -> unix + 86400
            end
        end
    end
  end

  defp eval_session_id(%{"session_id" => session_id})
       when is_binary(session_id) and session_id != "" do
    session_id
  end

  defp eval_session_id(_), do: nil
end
