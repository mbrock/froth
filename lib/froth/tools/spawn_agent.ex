defmodule Froth.Tools.SpawnAgent do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.{Config, CycleRuntime, Message, TaskBridge, ToolUse}
  alias Froth.Repo
  alias Froth.Telegram.Bot
  alias Froth.Telegram.Bot.Config, as: BotConfig
  alias Froth.Telegram.CycleLink
  alias Froth.Tools.Support

  @default_model "gpt-5.4-mini"
  @default_tool_names ["run_shell", "elixir_eval"]

  @impl true
  def name, do: "spawn_agent"

  @impl true
  def label, do: "spawn agent"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" =>
        "Start an ad-hoc sub-agent in the background and return its cycle ID. Use this when the task is bounded but would take multiple steps, benefit from parallelism, or is easier to delegate than to carry in the current loop. The prompt must be self-contained enough for the sub-agent to understand the job without extra chat context. By default the sub-agent gets run_shell and elixir_eval; you can restrict or remove tools if you want a narrower worker. The result includes the spawned cycle ID, task ID, and tool URL so you can inspect it later.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "prompt" => %{
            "type" => "string",
            "description" =>
              "Self-contained prompt for the delegated sub-agent, including the goal and any important constraints."
          },
          "model" => %{
            "type" => "string",
            "description" =>
              "Optional model for the sub-agent. Defaults to gpt-5.4-mini."
          },
          "tools" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Optional tool names to expose to the sub-agent. Defaults to [\"run_shell\", \"elixir_eval\"]. The alias \"shell\" is accepted for run_shell. Pass [] for a no-tools sub-agent."
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
  end

  @impl true
  def execute(%Context{} = ctx, %ToolUse{input: input}, _hooks)
      when is_map(input) do
    chat_id = Support.chat_id(ctx)

    if chat_id == 0 do
      {:error, "spawn_agent requires a valid chat_id"}
    else
      input_reply_to = reply_to_from_input(input)
      reply_to = input_reply_to || Support.reply_to(ctx)

      with {:ok, prompt} <- Support.required_trimmed_string(input, "prompt"),
           {:ok, model} <- Support.optional_trimmed_string(input, "model"),
           {:ok, system_prompt} <-
             Support.optional_trimmed_string(input, "system_prompt"),
           {:ok, tool_names, tool_specs} <- resolve_tools(input),
           {:ok, {cycle, task_id, _pid}} <-
             start_cycle(
               ctx,
               prompt,
               tool_specs,
               chat_id,
               reply_to,
               model: model || @default_model,
               system_prompt: system_prompt
             ) do
        {:ok, result(ctx, cycle, tool_names, task_id)}
      end
    end
  end

  defp start_cycle(
         %Context{} = ctx,
         prompt,
         tool_specs,
         chat_id,
         reply_to,
         extra_opts
       )
       when is_binary(prompt) and is_list(tool_specs) and is_integer(chat_id) and
              is_list(extra_opts) do
    parent_cycle_id = ctx.cycle_id
    bc = ctx.bot_config
    bot_id = bc && bc.id

    with {:ok, bot_ref} <- bot_ref(bot_id),
         config = build_config(ctx, chat_id, reply_to, tool_specs, extra_opts),
         user_message =
           Repo.insert!(%Message{role: :user, content: Message.wrap(prompt)}),
         cycle = Froth.Agent.begin_cycle(user_message, config),
         :ok <- maybe_link_spawned_cycle(cycle, chat_id, bot_id, reply_to),
         {:ok, task_id} <-
           TaskBridge.create_spawned_agent_task(cycle, prompt,
             bot_id: bot_id,
             chat_id: chat_id,
             reply_to: reply_to,
             parent_cycle_id: parent_cycle_id
           ) do
      spawn_opts =
        [
          cycle_id: cycle.id,
          cycle: cycle,
          worker_config: config,
          chat_id: chat_id,
          reply_to: reply_to,
          bot_id: bot_id,
          parent_cycle_id: parent_cycle_id,
          spam: ctx.spam
        ]
        |> Keyword.reject(fn {_k, v} -> is_nil(v) end)

      case CycleRuntime.start_for_bot(bot_ref, spawn_opts) do
        {:ok, runtime_pid} ->
          {:ok, {cycle, task_id, runtime_pid}}

        {:error, :bot_not_running} ->
          :ok =
            Froth.Tasks.fail(
              task_id,
              "failed to start sub-agent runtime: owning bot is not running",
              %{"cycle_id" => cycle.id, "cycle_status" => "failed"}
            )

          {:error,
           "failed to start sub-agent runtime: owning bot is not running"}

        {:error, reason} ->
          :ok =
            Froth.Tasks.fail(
              task_id,
              "failed to start sub-agent runtime: #{inspect(reason)}",
              %{"cycle_id" => cycle.id, "cycle_status" => "failed"}
            )

          {:error, "failed to start sub-agent runtime: #{inspect(reason)}"}
      end
    end
  end

  defp build_config(
         %Context{} = ctx,
         chat_id,
         reply_to,
         tool_specs,
         extra_opts
       ) do
    bc = ctx.bot_config

    %Config{
      provider: nil,
      system:
        Keyword.get(extra_opts, :system_prompt) ||
          "You are a helpful assistant. Use the available tools when needed.",
      model: Keyword.fetch!(extra_opts, :model),
      tools: tool_specs,
      tool_executor: nil,
      context:
        %{}
        |> maybe_put_context(:chat_id, chat_id)
        |> maybe_put_context(:reply_to, reply_to)
        |> maybe_put_context(:bot_id, bc && bc.id)
        |> maybe_put_context(:session_id, bc && bc.session_id)
        |> maybe_put_context(:bot_username, bc && bc.bot_username),
      parent_span_id: nil,
      thinking: nil,
      effort: nil,
      reasoning_summary: nil
    }
  end

  defp bot_ref(bot_id) when is_binary(bot_id) and bot_id != "" do
    case Bot.snapshot(bot_id) do
      {_pid, _config} -> {:ok, bot_id}
    end
  rescue
    RuntimeError -> {:error, "spawn_agent requires a running owning bot"}
  end

  defp bot_ref(_bot_id), do: {:error, "spawn_agent requires an owning bot"}

  defp maybe_put_context(map, _key, nil), do: map
  defp maybe_put_context(map, key, value), do: Map.put(map, key, value)

  defp maybe_link_spawned_cycle(%{id: cycle_id}, chat_id, bot_id, reply_to)
       when is_binary(cycle_id) and is_integer(chat_id) and is_binary(bot_id) do
    Repo.insert!(%CycleLink{
      cycle_id: cycle_id,
      bot_id: bot_id,
      chat_id: chat_id,
      reply_to: reply_to
    })

    :ok
  end

  defp maybe_link_spawned_cycle(_cycle, _chat_id, _bot_id, _reply_to), do: :ok

  defp result(%Context{bot_config: bc}, cycle, tool_names, task_id)
       when is_list(tool_names) do
    %{
      "status" => "started",
      "cycle_id" => cycle.id,
      "task_id" => task_id,
      "model" => cycle.model,
      "tools" => tool_names,
      "check_hint" =>
        "Use the cycle URL to inspect the spawned agent, or follow task #{task_id} through the task tools."
    }
    |> maybe_put_result("open_url", open_url(bc, cycle.id))
  end

  defp open_url(%BotConfig{id: bot_id, bot_username: username}, cycle_id)
       when is_binary(cycle_id) and is_binary(bot_id) and bot_id != "" and
              is_binary(username) and
              username != "" do
    "https://t.me/#{username}/tool?startapp=cycle_#{bot_id}_#{cycle_id}"
  end

  defp open_url(_bot_config, _cycle_id), do: nil

  defp maybe_put_result(map, _key, nil), do: map
  defp maybe_put_result(map, key, value), do: Map.put(map, key, value)

  defp reply_to_from_input(input) when is_map(input) do
    case Map.get(input, "reply_to") do
      reply_to when is_integer(reply_to) -> reply_to
      _ -> nil
    end
  end

  defp resolve_tools(input) when is_map(input) do
    case Map.fetch(input, "tools") do
      :error ->
        resolve_tool_names(@default_tool_names)

      {:ok, nil} ->
        resolve_tool_names(@default_tool_names)

      {:ok, tools} when is_list(tools) ->
        resolve_tool_names(tools)

      {:ok, _other} ->
        {:error, "tools must be an array of strings"}
    end
  end

  defp resolve_tool_names(names) when is_list(names) do
    with {:ok, normalized_names} <- normalize_tool_names(names) do
      available_specs =
        Map.new(Froth.Inference.Tools.specs_for_api(), &{&1["name"], &1})

      case Enum.filter(
             normalized_names,
             &(not Map.has_key?(available_specs, &1))
           ) do
        [] ->
          {:ok, normalized_names,
           Enum.map(normalized_names, &Map.fetch!(available_specs, &1))}

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

  defp normalize_tool_names(names) when is_list(names) do
    Enum.reduce_while(names, {:ok, {MapSet.new(), []}}, fn
      name, {:ok, {seen, acc}} when is_binary(name) ->
        normalized_name =
          name
          |> String.trim()
          |> canonical_tool_name()

        cond do
          normalized_name == "" ->
            {:halt, {:error, "tools must be an array of non-empty strings"}}

          MapSet.member?(seen, normalized_name) ->
            {:cont, {:ok, {seen, acc}}}

          true ->
            {:cont,
             {:ok,
              {MapSet.put(seen, normalized_name), acc ++ [normalized_name]}}}
        end

      _name, _acc ->
        {:halt, {:error, "tools must be an array of strings"}}
    end)
    |> case do
      {:ok, {_seen, acc}} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_tool_name("shell"), do: "run_shell"
  defp canonical_tool_name(name), do: name
end
