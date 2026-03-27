defmodule Froth.Agent.AdhocToolExecutor do
  @moduledoc false

  use GenServer

  alias Froth.Agent.ToolUse
  alias Froth.Inference.Tools
  alias Froth.Telegram.ControlPrompt
  alias Froth.Telegram.ToolExecution

  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) when is_list(opts) do
    {:ok,
     %{
       bot_id: Keyword.fetch!(opts, :bot_id),
       bot_username: Keyword.get(opts, :bot_username),
       session_id: Keyword.fetch!(opts, :session_id),
       chat_id: Keyword.get(opts, :chat_id),
       reply_to: Keyword.get(opts, :reply_to),
       prompt: Keyword.get(opts, :prompt),
       model: Keyword.get(opts, :model),
       provider: Keyword.get(opts, :provider),
       spam: Keyword.get(opts, :spam, true),
       tool_execution_module: Keyword.get(opts, :tool_execution_module, ToolExecution),
       control_prompt_cycles: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:prepare_tool, %ToolUse{} = tool_use, context}, _from, state) do
    {reply, state} = prepare_tool(tool_use, context, state)
    {:reply, reply, state}
  end

  def handle_call({:commit_tool, _tool_use, _context, _prepared, outcome}, _from, state) do
    {:reply, normalize_tool_outcome(outcome), state}
  end

  def handle_call({:execute, %ToolUse{} = tool_use, context}, _from, state) do
    reply =
      tool_use
      |> build_execution(context, state, false)
      |> execute_direct()
      |> normalize_tool_outcome()

    {:reply, reply, state}
  end

  defp prepare_tool(%ToolUse{name: "send_message"} = tool_use, context, state) do
    case resolved_chat_id(context, state) do
      chat_id when is_integer(chat_id) and chat_id != 0 ->
        {prepare_tool_execution(tool_use, context, state, "send_message"), state}

      _ ->
        {{:error, "send_message requires chat_id"}, state}
    end
  end

  defp prepare_tool(%ToolUse{} = tool_use, context, state) do
    cycle_id = context_value(context, :cycle_id)
    {state, send_control_prompt?} = reserve_control_prompt(state, cycle_id)
    {prepare_tool_execution(tool_use, context, state, nil, send_control_prompt?), state}
  end

  defp prepare_tool_execution(tool_use, context, state, expected_name) do
    prepare_tool_execution(tool_use, context, state, expected_name, false)
  end

  defp prepare_tool_execution(
         %ToolUse{} = tool_use,
         context,
         state,
         expected_name,
         send_control_prompt?
       ) do
    if is_binary(expected_name) and tool_use.name != expected_name do
      {:error, "unexpected tool name"}
    else
      case build_execution(tool_use, context, state, send_control_prompt?) do
        %{input: input} = execution when is_map(input) ->
          {:ok,
           %{
             execution: execution,
             execute: execute_spec(execution, state)
           }}

        _ ->
          {:error, "invalid tool input"}
      end
    end
  end

  defp build_execution(%ToolUse{name: name, input: input}, context, state, send_control_prompt?)
       when is_map(input) do
    cycle_id = context_value(context, :cycle_id)
    chat_id = resolved_chat_id(context, state)
    reply_to = resolved_reply_to(context, state)

    base_input =
      input
      |> maybe_put_reply_to(name, reply_to)
      |> maybe_put_narration_markdown()

    input =
      case name do
        "elixir_eval" ->
          base_input
          |> maybe_put_topic(cycle_id)

        _ ->
          base_input
      end

    input =
      input
      |> Map.put("send_control_prompt", send_control_prompt?)
      |> maybe_put_control_prompt(send_control_prompt?, cycle_id, chat_id, reply_to, state)

    %{
      name: name,
      input: input,
      tool_use_id: context_value(context, :tool_use_id),
      bot_id: state.bot_id,
      bot_username: state.bot_username,
      session_id: state.session_id,
      chat_id: chat_id,
      reply_to: reply_to,
      cycle_id: cycle_id,
      model: state.model,
      spam: state.spam
    }
  end

  defp build_execution(%ToolUse{name: name}, context, state, _send_control_prompt?) do
    %{
      name: name,
      input: nil,
      tool_use_id: context_value(context, :tool_use_id),
      bot_id: state.bot_id,
      bot_username: state.bot_username,
      session_id: state.session_id,
      chat_id: resolved_chat_id(context, state),
      reply_to: resolved_reply_to(context, state),
      cycle_id: context_value(context, :cycle_id),
      model: state.model,
      spam: state.spam
    }
  end

  defp execute_spec(execution, state) do
    if use_tool_execution?(execution, state) do
      {state.tool_execution_module, :execute, [execution]}
    else
      {__MODULE__, :execute_direct, [execution]}
    end
  end

  def execute_direct(%{name: "send_message"}) do
    %{result: {:error, "send_message requires chat_id"}}
  end

  def execute_direct(%{name: name, input: input} = execution)
      when is_binary(name) and is_map(input) do
    chat_id = execution[:chat_id] || 0
    opts = direct_tool_opts(execution)
    %{result: Tools.execute(name, input, chat_id, opts)}
  end

  def execute_direct(_execution), do: %{result: {:error, "invalid tool execution context"}}

  defp direct_tool_opts(execution) do
    []
    |> maybe_put_kw(:session_id, execution[:session_id])
    |> maybe_put_kw(:bot_id, bot_id_for_direct_execution(execution))
    |> maybe_put_kw(:bot_username, execution[:bot_username])
    |> maybe_put_kw(:cycle_id, execution[:cycle_id])
    |> maybe_put_kw(:reply_to, execution[:reply_to])
    |> maybe_put_kw(:topic, execution[:input]["topic"])
    |> maybe_put_kw(:spam, execution[:spam])
  end

  defp bot_id_for_direct_execution(%{chat_id: chat_id, bot_id: bot_id})
       when is_integer(chat_id) and chat_id != 0 and is_binary(bot_id) do
    bot_id
  end

  defp bot_id_for_direct_execution(_execution), do: nil

  defp normalize_tool_outcome(%{result: result}), do: result
  defp normalize_tool_outcome(result), do: result

  defp use_tool_execution?(%{chat_id: chat_id}, %{tool_execution_module: module})
       when is_integer(chat_id) and chat_id != 0 and is_atom(module) do
    true
  end

  defp use_tool_execution?(_execution, _state), do: false

  defp resolved_chat_id(context, state) do
    context_value(context, :chat_id) || state.chat_id
  end

  defp resolved_reply_to(context, state) do
    context_value(context, :reply_to) || state.reply_to
  end

  defp context_value(context, key) when is_map(context) do
    Map.get(context, key) || Map.get(context, Atom.to_string(key))
  end

  defp context_value(_context, _key), do: nil

  defp maybe_put_kw(keyword, _key, nil), do: keyword
  defp maybe_put_kw(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp reserve_control_prompt(state, cycle_id) do
    {cycles, send_control_prompt?} = ControlPrompt.reserve(state.control_prompt_cycles, cycle_id)
    {%{state | control_prompt_cycles: cycles}, send_control_prompt?}
  end

  defp maybe_put_reply_to(input, name, reply_to)
       when name in ["elixir_eval", "run_shell", "spawn_agent"] and is_map(input) do
    Map.put(input, "reply_to", reply_to)
  end

  defp maybe_put_reply_to(input, _name, _reply_to), do: input

  defp maybe_put_topic(input, cycle_id) when is_map(input) and is_binary(cycle_id) do
    Map.put(input, "topic", "cycle:#{cycle_id}")
  end

  defp maybe_put_topic(input, _cycle_id), do: input

  defp maybe_put_control_prompt(input, true, cycle_id, chat_id, reply_to, state)
       when is_map(input) and is_binary(cycle_id) and is_integer(chat_id) and
              is_binary(state.session_id) do
    ControlPrompt.maybe_put(
      input,
      true,
      cycle_id: cycle_id,
      chat_id: chat_id,
      reply_to: reply_to,
      session_id: state.session_id,
      bot_id: state.bot_id,
      bot_username: state.bot_username,
      markdown: control_prompt_markdown(state)
    )
  end

  defp maybe_put_control_prompt(input, _send?, _cycle_id, _chat_id, _reply_to, _state), do: input

  defp maybe_put_narration_markdown(input) when is_map(input) do
    case Map.get(input, "narration") do
      narration when is_binary(narration) ->
        trimmed = String.trim(narration)

        if trimmed == "" do
          input
        else
          Map.put(
            input,
            "narration_markdown",
            "_" <> ControlPrompt.markdown_escape(trimmed) <> "_"
          )
        end

      _ ->
        input
    end
  end

  defp control_prompt_markdown(state) do
    ControlPrompt.adhoc_markdown(state.model, state.provider, state.prompt)
  end
end
