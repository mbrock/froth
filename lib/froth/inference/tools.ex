defmodule Froth.Inference.Tools do
  @moduledoc """
  Tool catalog and execution for inference sessions.
  """

  alias Froth.Agent.{Surface, ToolUse}
  alias Froth.Agent.CycleRuntime.{Context, View}
  alias Froth.Telegram.Bot.Config, as: BotConfig
  alias Froth.Tools.Ask, as: AskTool
  alias Froth.Tools.Await, as: AwaitTool
  alias Froth.Tools.ElixirEval, as: ElixirEvalTool
  alias Froth.Tools.ListTasks, as: ListTasksTool
  alias Froth.Tools.Fetch, as: FetchTool
  alias Froth.Tools.Pager, as: PagerTool
  alias Froth.Tools.RegisterHeadlines, as: RegisterHeadlinesTool
  alias Froth.Tools.RunShell, as: RunShellTool
  alias Froth.Tools.SendInput, as: SendInputTool
  alias Froth.Tools.SpawnAgent, as: SpawnAgentTool
  alias Froth.Tools.SpawnEngineer, as: SpawnEngineerTool
  alias Froth.Tools.StopTask, as: StopTaskTool
  alias Froth.Tools.SubscribeTask, as: SubscribeTaskTool
  alias Froth.Tools.TaskOutput, as: TaskOutputTool
  alias Froth.Tools.Timeline, as: TimelineTool
  alias Froth.Tools.ViewAnalysis, as: ViewAnalysisTool

  @extracted_tool_modules [
    AskTool,
    AwaitTool,
    SpawnAgentTool,
    ElixirEvalTool,
    RunShellTool,
    SendInputTool,
    ListTasksTool,
    TaskOutputTool,
    StopTaskTool,
    SubscribeTaskTool,
    SpawnEngineerTool,
    PagerTool,
    ViewAnalysisTool,
    FetchTool,
    TimelineTool
  ]
  @callable_tool_modules [RegisterHeadlinesTool | @extracted_tool_modules]
  @tool_modules_by_name Map.new(@callable_tool_modules, &{&1.name(), &1})
  @tool_specs [
    %{
      "name" => "send_message",
      "description" =>
        "Send a visible text message to the current Telegram chat. Use this for actual user-facing reply text, not for internal notes or tool narration. For longer replies, send one paragraph or one finished thought at a time instead of silently composing a whole essay and sending it all at once at the end. If you need to ask the human for missing information and wait for their answer, prefer ask instead of trying to simulate a question with send_message.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "text" => %{
            "type" => "string",
            "description" => "The exact text to send to the chat."
          }
        },
        "required" => ["text"],
        "additionalProperties" => false
      }
    }
  ]

  def specs_for_api do
    @tool_specs ++ Enum.map(@extracted_tool_modules, & &1.spec())
  end

  def specs_for_names(names) when is_list(names) do
    wanted = MapSet.new(names)
    Enum.filter(specs_for_api(), &MapSet.member?(wanted, &1["name"]))
  end

  def label(name) when is_binary(name) do
    case Map.get(@tool_modules_by_name, name) do
      nil -> name
      module -> module.label()
    end
  end

  def label(_), do: "tool"

  @doc """
  Primary entry point. Takes a cycle-level `%Context{}` and the
  per-call `%ToolUse{}`; `hooks` carries optional test-only overrides
  (currently just `:send_message_fun`).
  """
  def execute(%Context{} = ctx, %ToolUse{name: name} = tool_call, hooks \\ [])
      when is_list(hooks) do
    case Map.get(@tool_modules_by_name, name) do
      nil ->
        {:error, "unknown tool: #{name}"}

      module ->
        module.execute(ctx, tool_call, hooks)
    end
  end

  @doc """
  Legacy 4-ary signature: `execute(name, input, chat_id, opts)`. Tests
  and ad-hoc callers that don't hold a full `%Context{}` use this
  shim; it synthesizes a Context from flat opts and delegates to the
  primary `execute/3`.
  """
  def execute(name, input, chat_id, opts)
      when is_binary(name) and is_map(input) and is_list(opts) do
    ctx = context_from_opts(chat_id, opts)

    tool_call = %ToolUse{
      id: opts[:tool_use_id] || "ad-hoc:#{name}",
      name: name,
      input: input
    }

    hooks = Keyword.take(opts, [:send_message_fun])

    execute(ctx, tool_call, hooks)
  end

  # Build a `%Context{}` from the legacy flat opts format. Used by the
  # 4-ary shim so tests and ad-hoc callers don't need to construct a
  # full Context themselves.
  defp context_from_opts(chat_id, opts) when is_list(opts) do
    %Context{
      cycle_id: opts[:cycle_id],
      cycle: nil,
      bot_config: bot_config_from_opts(opts),
      surface: %Surface{
        session_id: opts[:session_id],
        chat_id: chat_id,
        reply_to: opts[:reply_to]
      },
      view: %View{active_task_ids: opts[:active_task_ids] || []},
      spam: Keyword.get(opts, :spam, true),
      system_prompt: opts[:system_prompt],
      tool_specs: opts[:tools] || []
    }
  end

  # Synthetic BotConfig for the legacy shim path. Fills in minimal
  # required fields (bot_user_id/owner_user_id are not used by any
  # tool). Returns nil when there's not even a bot_id.
  defp bot_config_from_opts(opts) do
    case opts[:bot_id] do
      bid when is_binary(bid) ->
        %BotConfig{
          id: bid,
          session_id: opts[:session_id] || "",
          bot_username: opts[:bot_username] || "",
          bot_user_id: 0,
          owner_user_id: 0,
          model: opts[:model] || "",
          thinking: opts[:thinking],
          effort: opts[:effort],
          tools: opts[:tools],
          system_prompt: opts[:system_prompt]
        }

      _ ->
        nil
    end
  end
end
