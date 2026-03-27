defmodule Froth.Agent.Adhoc do
  @moduledoc false

  alias Froth.Agent
  alias Froth.Agent.{AdhocToolExecutor, Config, Cycle, Message}
  alias Froth.LLM
  alias Froth.Repo
  alias Froth.Telegram.{Charlie, Lennart}

  @default_bot_id "charlie"
  @default_session_id "charlie"
  @default_system "You are a helpful assistant. Use the available tools when needed."

  @spec start(String.t(), keyword()) :: {Cycle.t(), Enumerable.t()}
  def start(prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    resolved = resolve_options(prompt, opts)

    case resolve_tool_executor(opts, resolved) do
      {:existing, tool_executor} ->
        start_with_tool_executor(resolved, tool_executor)

      {:started, pid} ->
        {cycle, stream} = start_with_tool_executor(resolved, pid)
        {cycle, stream_with_cleanup(stream, pid)}
    end
  end

  @spec run(String.t(), keyword()) :: {Cycle.t(), term()}
  def run(prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    {cycle, stream} = start(prompt, opts)

    last_agent_message =
      Enum.reduce(stream, nil, fn
        {:event, _event, %Message{role: :agent} = message}, _acc -> message
        _item, acc -> acc
      end)

    {Repo.get!(Cycle, cycle.id), output_for(last_agent_message)}
  end

  defp start_with_tool_executor(%{prompt: prompt} = resolved, tool_executor) do
    config = build_config(resolved, tool_executor)
    cycle = create_cycle(config)
    {_message, _head_id} = Agent.append_message(cycle, nil, :user, prompt)
    Agent.run(cycle, config)
  end

  defp stream_with_cleanup(stream, pid) when is_pid(pid) do
    Stream.transform(
      stream,
      fn -> nil end,
      fn item, acc -> {[item], acc} end,
      fn _acc ->
        if Process.alive?(pid) do
          GenServer.stop(pid, :normal, 5_000)
        end
      end
    )
  end

  defp resolve_tool_executor(opts, %{runtime: runtime} = resolved)
       when is_list(opts) and is_map(runtime) do
    case Keyword.get(opts, :tool_executor) do
      nil ->
        {:ok, pid} =
          AdhocToolExecutor.start_link(
            bot_id: runtime.bot_id,
            bot_username: runtime.bot_username,
            session_id: runtime.session_id,
            chat_id: runtime.chat_id,
            reply_to: runtime.reply_to,
            prompt: resolved.prompt,
            system_prompt: resolved.system,
            model: resolved.model,
            provider: resolved.provider_name,
            tools: resolved.tools,
            thinking: resolved.thinking,
            effort: resolved.effort,
            tool_timeout_ms: resolved.tool_timeout_ms,
            spam: Keyword.get(opts, :spam, true)
          )

        {:started, pid}

      tool_executor ->
        {:existing, tool_executor}
    end
  end

  defp build_config(%{runtime: runtime} = resolved, tool_executor)
       when is_map(runtime) do
    context =
      %{}
      |> maybe_put(:chat_id, runtime.chat_id)
      |> maybe_put(:reply_to, runtime.reply_to)
      |> maybe_put(:bot_id, runtime.bot_id)
      |> maybe_put(:session_id, runtime.session_id)
      |> maybe_put(:bot_username, runtime.bot_username)
      |> Map.merge(resolved.context)

    %Config{
      provider: resolved.provider,
      system: resolved.system,
      model: resolved.model,
      tools: resolved.tools,
      tool_executor: tool_executor,
      tool_timeout_ms: resolved.tool_timeout_ms,
      context: context,
      parent_span_id: resolved.parent_span_id,
      thinking: resolved.thinking,
      effort: resolved.effort,
      reasoning_summary: resolved.reasoning_summary
    }
  end

  defp create_cycle(%Config{} = config) do
    %Cycle{}
    |> Cycle.changeset(Agent.cycle_snapshot_attrs(config))
    |> Repo.insert!()
  end

  defp output_for(nil), do: nil

  defp output_for(%Message{} = message) do
    Message.extract_text(message) || message.content
  end

  defp resolve_options(prompt, opts) when is_binary(prompt) and is_list(opts) do
    provider = provider_option(opts)
    model = resolve_model(opts, provider)

    %{
      prompt: prompt,
      provider: provider,
      provider_name: resolve_provider_name(provider, model),
      system: Keyword.get(opts, :system, @default_system),
      model: model,
      tools: normalize_tools(Keyword.get(opts, :tools)),
      tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms),
      context: normalize_map(Keyword.get(opts, :context)),
      parent_span_id: Keyword.get(opts, :parent_span_id),
      thinking: normalize_map(Keyword.get(opts, :thinking)),
      effort: Keyword.get(opts, :effort),
      reasoning_summary: string_option(opts, :reasoning_summary),
      runtime: resolve_runtime(opts)
    }
  end

  defp resolve_runtime(opts) when is_list(opts) do
    bot_id = string_option(opts, :bot_id) || @default_bot_id
    chat_id = integer_option(opts, :chat_id)
    reply_to = integer_option(opts, :reply_to)
    bot_runtime = lookup_bot_runtime(bot_id, chat_id)
    bot_defaults = bot_defaults(bot_id)

    %{
      bot_id: bot_id,
      bot_username:
        string_option(opts, :bot_username) || bot_runtime.bot_username ||
          bot_defaults.bot_username,
      session_id:
        string_option(opts, :session_id) || bot_runtime.session_id ||
          bot_defaults.session_id || @default_session_id,
      chat_id: chat_id,
      reply_to: reply_to
    }
  end

  defp lookup_bot_runtime(_bot_id, chat_id) when not is_integer(chat_id),
    do: %{session_id: nil, bot_username: nil}

  defp lookup_bot_runtime(bot_id, _chat_id) when is_binary(bot_id) do
    if Process.whereis(Froth.Telegram.BotRegistry) do
      case Registry.lookup(Froth.Telegram.BotRegistry, bot_id) do
        [{pid, _value} | _rest] -> bot_runtime_from_pid(pid)
        [] -> %{session_id: nil, bot_username: nil}
      end
    else
      %{session_id: nil, bot_username: nil}
    end
  end

  defp bot_runtime_from_pid(pid) when is_pid(pid) do
    try do
      case :sys.get_state(pid) do
        %{bot_config: %{session_id: session_id, bot_username: bot_username}}
        when is_binary(session_id) and is_binary(bot_username) ->
          %{
            session_id: session_id,
            bot_username: bot_username
          }

        _ ->
          %{session_id: nil, bot_username: nil}
      end
    catch
      :exit, _reason ->
        %{session_id: nil, bot_username: nil}
    end
  end

  defp bot_defaults("charlie"), do: charlie_defaults()
  defp bot_defaults("lennart"), do: lennart_defaults()
  defp bot_defaults(_bot_id), do: %{session_id: nil, bot_username: nil}

  defp charlie_defaults do
    cfg = Charlie.default_config()

    %{
      session_id: cfg.session_id,
      bot_username: cfg.bot_username
    }
  end

  defp lennart_defaults do
    cfg = Lennart.default_config()

    %{
      session_id: cfg.session_id,
      bot_username: cfg.bot_username
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}

  defp normalize_tools(tools) when is_list(tools), do: tools
  defp normalize_tools(_tools), do: []

  defp provider_option(opts) when is_list(opts) do
    case Keyword.get(opts, :provider) do
      nil ->
        nil

      value when is_atom(value) ->
        value

      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value ->
        raise ArgumentError,
              "expected :provider to be an atom, module, or string, got: #{inspect(value)}"
    end
  end

  defp resolve_model(opts, _provider) when is_list(opts) do
    string_option(opts, :model)
  end

  defp resolve_provider_name(provider, model) do
    case LLM.resolve_provider_name(provider, model) do
      nil -> nil
      name -> Atom.to_string(name)
    end
  end

  defp string_option(opts, key) when is_list(opts) and is_atom(key) do
    case Keyword.get(opts, key) do
      nil ->
        nil

      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value ->
        raise ArgumentError, "expected #{inspect(key)} to be a string, got: #{inspect(value)}"
    end
  end

  defp integer_option(opts, key) when is_list(opts) and is_atom(key) do
    case Keyword.get(opts, key) do
      nil ->
        nil

      value when is_integer(value) ->
        value

      value ->
        raise ArgumentError, "expected #{inspect(key)} to be an integer, got: #{inspect(value)}"
    end
  end
end
