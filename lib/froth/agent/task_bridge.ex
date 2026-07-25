defmodule Froth.Agent.TaskBridge do
  @moduledoc false

  alias Froth.Agent
  alias Froth.Agent.{Cycle, Message}
  alias Froth.Tasks

  @task_prefix "agent"
  @final_reply_max_chars 4_000

  @spec task_id_for_cycle(Cycle.t() | String.t()) :: String.t() | nil
  def task_id_for_cycle(%Cycle{id: cycle_id}), do: task_id_for_cycle(cycle_id)

  def task_id_for_cycle(cycle_id) when is_binary(cycle_id),
    do: "#{@task_prefix}:#{cycle_id}"

  def task_id_for_cycle(_cycle_id), do: nil

  @spec create_spawned_agent_task(Cycle.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def create_spawned_agent_task(%Cycle{} = cycle, prompt, opts \\ [])
      when is_binary(prompt) and is_list(opts) do
    task_id = task_id_for_cycle(cycle)

    with {:ok, _task} <-
           Tasks.create(%{
             task_id: task_id,
             type: "agent",
             label: prompt_label(prompt),
             metadata: task_metadata(cycle, opts)
           }),
         :ok <- maybe_subscribe_telegram(task_id, opts),
         :ok <- Tasks.start(task_id) do
      {:ok, task_id}
    end
  end

  @spec sync_cycle_task(Cycle.t(), Cycle.status(), map()) :: :ok
  def sync_cycle_task(%Cycle{} = cycle, status, extra \\ %{})
      when status in [:completed, :failed, :cancelled] and is_map(extra) do
    case {task_id_for_cycle(cycle), cycle_task(cycle)} do
      {task_id, %Froth.Task{status: task_status}}
      when task_status in ["pending", "running"] ->
        metadata = completion_metadata(cycle, status, extra)
        append_completion_output(task_id, status, metadata)
        finish_task(task_id, status, metadata)

      _ ->
        :ok
    end
  end

  defp cycle_task(%Cycle{} = cycle) do
    cycle
    |> task_id_for_cycle()
    |> case do
      task_id when is_binary(task_id) -> Tasks.get(task_id)
      _ -> nil
    end
  end

  defp finish_task(task_id, :completed, metadata)
       when is_binary(task_id) and is_map(metadata) do
    :ok = Tasks.complete(task_id, metadata)
  end

  defp finish_task(task_id, :failed, metadata)
       when is_binary(task_id) and is_map(metadata) do
    :ok = Tasks.fail(task_id, task_error(metadata), metadata)
  end

  defp finish_task(task_id, :cancelled, metadata)
       when is_binary(task_id) and is_map(metadata) do
    :ok = Tasks.stop(task_id, metadata)
  end

  defp append_completion_output(task_id, :completed, metadata)
       when is_binary(task_id) and is_map(metadata) do
    case metadata["final_reply"] do
      reply when is_binary(reply) and reply != "" ->
        Tasks.append_output(task_id, ensure_trailing_newline(reply))
        :ok

      _ ->
        :ok
    end
  end

  defp append_completion_output(task_id, :failed, metadata)
       when is_binary(task_id) and is_map(metadata) do
    case task_error(metadata) do
      error when is_binary(error) and error != "" ->
        Tasks.append(task_id, "stderr", ensure_trailing_newline(error))
        :ok

      _ ->
        :ok
    end
  end

  defp append_completion_output(_task_id, _status, _metadata), do: :ok

  defp task_metadata(%Cycle{} = cycle, opts) when is_list(opts) do
    %{}
    |> maybe_put("cycle_id", cycle.id)
    |> maybe_put("model", cycle.model)
    |> maybe_put("bot_id", Keyword.get(opts, :bot_id))
    |> maybe_put("chat_id", Keyword.get(opts, :chat_id))
    |> maybe_put("reply_to", Keyword.get(opts, :reply_to))
    |> maybe_put("parent_cycle_id", Keyword.get(opts, :parent_cycle_id))
  end

  defp completion_metadata(%Cycle{} = cycle, status, extra)
       when is_map(extra) do
    %{}
    |> maybe_put("cycle_id", cycle.id)
    |> maybe_put("cycle_status", Atom.to_string(status))
    |> maybe_put("model", cycle.model)
    |> maybe_put("final_reply", final_reply_text(cycle))
    |> maybe_put("error", cycle_error(extra))
  end

  defp final_reply_text(%Cycle{} = cycle) do
    cycle
    |> Agent.list_messages()
    |> Enum.reverse()
    |> Enum.find(&match?(%Message{role: :agent}, &1))
    |> case do
      %Message{} = message ->
        message
        |> message_text()
        |> truncate(@final_reply_max_chars)

      _ ->
        nil
    end
  end

  defp message_text(%Message{} = message) do
    case Message.extract_text(message) do
      text when is_binary(text) ->
        text
        |> String.trim()
        |> case do
          "" -> summarize_content(message.content)
          trimmed -> trimmed
        end

      _ ->
        summarize_content(message.content)
    end
  end

  defp summarize_content(content) when is_list(content) do
    content
    |> Enum.map_join("\n", fn block ->
      inspect(block, pretty: true, limit: 20, printable_limit: 1_200)
    end)
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp task_error(metadata) when is_map(metadata) do
    metadata["error"] || metadata["final_reply"] || "agent task failed"
  end

  defp cycle_error(extra) when is_map(extra) do
    extra["error"] || extra[:error]
  end

  defp maybe_subscribe_telegram(task_id, opts)
       when is_binary(task_id) and is_list(opts) do
    bot_id = Keyword.get(opts, :bot_id)
    chat_id = Keyword.get(opts, :chat_id)
    reply_to = Keyword.get(opts, :reply_to)

    if is_binary(bot_id) and is_integer(chat_id) do
      case Tasks.subscribe_telegram(task_id, bot_id, chat_id,
             message_id: reply_to
           ) do
        {:ok, _link} -> :ok
        {:error, _reason} = error -> error
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp ensure_trailing_newline(text) when is_binary(text) do
    if String.ends_with?(text, "\n"), do: text, else: text <> "\n"
  end

  defp prompt_label(prompt) when is_binary(prompt) do
    prompt
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> "Agent task"
      compact -> String.slice(compact, 0, 120)
    end
  end

  defp truncate(nil, _max_chars), do: nil

  defp truncate(text, max_chars)
       when is_binary(text) and is_integer(max_chars) and max_chars > 0 do
    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars) <> "..."
    else
      text
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
