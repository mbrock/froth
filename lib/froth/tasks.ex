defmodule Froth.Tasks do
  @moduledoc """
  Unified task management. Every background unit of work — shell commands,
  analyzers, eval sessions, etc. — is represented as a task with an event
  stream persisted in Postgres.
  """

  alias Froth.{Repo, Task, TaskEvent, TaskTelegramLink}
  alias Froth.Telegram.{BotAdapter, SyntheticMessage}
  alias Span
  import Ecto.Query

  @pubsub Froth.PubSub

  # --- Lifecycle ---

  def create(attrs) when is_map(attrs) do
    changeset = Task.changeset(%Task{}, attrs)

    case Repo.insert(changeset) do
      {:ok, task} ->
        Span.execute([:froth, :tasks, :created], nil, %{
          task_id: task.task_id,
          type: task.type,
          label: task.label
        })

        append(task.task_id, "status", "created")
        {:ok, task}

      error ->
        error
    end
  end

  def start(task_id) when is_binary(task_id) do
    now = DateTime.utc_now()

    {1, _} =
      from(t in Task, where: t.task_id == ^task_id)
      |> Repo.update_all(set: [status: "running", started_at: now])

    Span.execute([:froth, :tasks, :started], nil, %{task_id: task_id})
    append(task_id, "status", "running")
    :ok
  end

  def complete(task_id, metadata_updates \\ %{}) when is_binary(task_id) do
    now = DateTime.utc_now()

    from(t in Task, where: t.task_id == ^task_id)
    |> Repo.update_all(
      set: [status: "completed", finished_at: now],
      push: []
    )

    if metadata_updates != %{} do
      merge_metadata(task_id, metadata_updates)
    end

    Span.execute([:froth, :tasks, :completed], nil, %{
      task_id: task_id,
      metadata: metadata_updates
    })

    append(task_id, "status", "completed")
    fire_notifications(task_id)
    :ok
  end

  def fail(task_id, reason, metadata_updates \\ %{})
      when is_binary(task_id) and is_binary(reason) and
             is_map(metadata_updates) do
    now = DateTime.utc_now()

    from(t in Task, where: t.task_id == ^task_id)
    |> Repo.update_all(set: [status: "failed", finished_at: now])

    if metadata_updates != %{} do
      merge_metadata(task_id, metadata_updates)
    end

    Span.execute([:froth, :tasks, :failed], nil, %{
      task_id: task_id,
      reason: String.slice(reason, 0, 200),
      metadata: metadata_updates
    })

    append(task_id, "status", "failed: #{reason}")
    fire_notifications(task_id)
    :ok
  end

  def stop(task_id, metadata_updates \\ %{})
      when is_binary(task_id) and is_map(metadata_updates) do
    now = DateTime.utc_now()

    from(t in Task, where: t.task_id == ^task_id)
    |> Repo.update_all(set: [status: "stopped", finished_at: now])

    if metadata_updates != %{} do
      merge_metadata(task_id, metadata_updates)
    end

    Span.execute([:froth, :tasks, :stopped], nil, %{
      task_id: task_id,
      metadata: metadata_updates
    })

    append(task_id, "status", "stopped")
    fire_notifications(task_id)
    :ok
  end

  # --- Events ---

  def append(task_id, kind, content)
      when is_binary(task_id) and is_binary(kind) do
    content = content |> to_string() |> sanitize_event_content()
    now = DateTime.utc_now()

    seq = next_sequence(task_id)

    {:ok, event} =
      %TaskEvent{}
      |> TaskEvent.changeset(%{
        task_id: task_id,
        sequence: seq,
        kind: kind,
        content: content,
        emitted_at: now
      })
      |> Repo.insert(log: false)

    Froth.broadcast("task:#{task_id}", {:task_event, task_id, event})
    event
  end

  def append_output(task_id, content) when is_binary(task_id) do
    append(task_id, "stdout", content)
  end

  # task_events.content is a Postgres text column, which rejects NUL
  # bytes and invalid UTF-8. That used to take down the shell
  # GenServer the first time a binary chunk (e.g. `cat foo.png`)
  # arrived on stdout — the port callback crashed on a failed
  # `{:ok, _} = Repo.insert(...)` match, the task died, task_events
  # ended up empty, and from the agent's side `task_output` returned
  # "No output for task." for a command that looked like it succeeded.
  #
  # Rather than try to store the raw bytes here (the right place for
  # those is a blob), we replace any non-JSON-text-safe chunk with a
  # short human-readable placeholder that tells the reader what we
  # dropped. MimeSniff picks a concrete MIME when it can; otherwise
  # the chunk is labeled `application/octet-stream`. The chunk is
  # still counted as one stdout event so ordering/stats stay honest.
  defp sanitize_event_content(content) when is_binary(content) do
    if Froth.Context.Blocks.json_text_safe?(content) do
      content
    else
      mime = Froth.MimeSniff.sniff(content) || "application/octet-stream"
      "[binary: #{mime} #{byte_size(content)} bytes]\n"
    end
  end

  # --- Queries ---

  def get(task_id) when is_binary(task_id) do
    Repo.get(Task, task_id)
  end

  def list_active(bot_id, chat_id \\ nil) when is_binary(bot_id) do
    reconcile_stale_process_tasks()

    query =
      from(t in Task,
        join: l in TaskTelegramLink,
        on: l.task_id == t.task_id,
        where: l.bot_id == ^bot_id and t.status in ["pending", "running"],
        distinct: t.task_id,
        order_by: [asc: t.inserted_at]
      )

    query =
      if chat_id do
        from([t, l] in query, where: l.chat_id == ^chat_id)
      else
        query
      end

    Repo.all(query, log: false)
  end

  def list_recent(bot_id, limit \\ 20) when is_binary(bot_id) do
    reconcile_stale_process_tasks()

    from(t in Task,
      join: l in TaskTelegramLink,
      on: l.task_id == t.task_id,
      where: l.bot_id == ^bot_id,
      distinct: t.task_id,
      order_by: [desc: t.inserted_at],
      limit: ^limit
    )
    |> Repo.all(log: false)
  end

  @doc "Marks process-backed tasks as stopped when their owning process is gone."
  def reconcile_stale_process_tasks do
    # Registry membership is node-local, so only reconcile records old enough
    # that they cannot plausibly be a task running on another Froth node.
    cutoff = DateTime.add(DateTime.utc_now(), -24, :hour)

    from(t in Task,
      where:
        t.status in ["pending", "running"] and
          t.type in ["shell", "eval", "codex"] and
          t.inserted_at < ^cutoff
    )
    |> Repo.all(log: false)
    |> Enum.each(fn task ->
      unless process_alive?(task) do
        stop(task.task_id, %{
          "stale" => true,
          "stale_reason" => "owner process not running"
        })
      end
    end)

    :ok
  end

  defp process_alive?(%Task{type: type, task_id: task_id})
       when type in ["shell", "eval"] do
    Froth.Tasks.Shell.alive?(task_id)
  end

  defp process_alive?(%Task{type: "codex", metadata: metadata}) do
    case metadata["session_id"] do
      session_id when is_binary(session_id) ->
        not is_nil(Froth.Codex.Session.whereis(session_id))

      _ ->
        false
    end
  end

  def recent_output(task_id, limit \\ 50) when is_binary(task_id) do
    from(e in TaskEvent,
      where: e.task_id == ^task_id and e.kind in ["stdout", "stderr"],
      order_by: [desc: e.sequence],
      limit: ^limit
    )
    |> Repo.all(log: false)
    |> Enum.reverse()
  end

  def output_stats(task_id, window_seconds \\ 30) when is_binary(task_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -window_seconds, :second)

    result =
      from(e in TaskEvent,
        where:
          e.task_id == ^task_id and
            e.kind in ["stdout", "stderr"] and
            e.emitted_at > ^cutoff,
        select: %{
          count: count(e.id),
          earliest: min(e.emitted_at),
          latest: max(e.emitted_at)
        }
      )
      |> Repo.one(log: false)

    count = result.count || 0

    rate =
      case {result.earliest, result.latest} do
        {nil, _} ->
          0.0

        {_, nil} ->
          0.0

        {earliest, latest} ->
          diff = DateTime.diff(latest, earliest, :millisecond)
          if diff > 0, do: count / (diff / 1000), else: 0.0
      end

    total =
      from(e in TaskEvent,
        where: e.task_id == ^task_id and e.kind in ["stdout", "stderr"],
        select: count(e.id)
      )
      |> Repo.one(log: false)

    %{count_in_window: count, rate_per_second: rate, total: total || 0}
  end

  # --- Context for agent ---

  def context_summary(bot_id, chat_id) when is_binary(bot_id) do
    tasks = list_active(bot_id, chat_id)

    if tasks == [] do
      ""
    else
      entries =
        Enum.map(tasks, fn task ->
          elapsed = format_elapsed(task.started_at)
          stats = output_stats(task.task_id)
          lines = recent_output(task.task_id, 5)

          rate_str =
            if stats.rate_per_second > 0,
              do: ", #{Float.round(stats.rate_per_second, 1)} lines/s",
              else: ""

          output_lines =
            lines
            |> Enum.map(fn e -> "  #{String.trim_trailing(e.content)}" end)
            |> Enum.join("\n")

          total_str =
            if stats.total > 0,
              do: "\n  (#{stats.total} lines total)",
              else: ""

          "[#{task.task_id}] #{task.label || task.type} -- #{task.status} #{elapsed}#{rate_str}\n#{output_lines}#{total_str}"
        end)

      "<active_tasks>\n#{Enum.join(entries, "\n\n")}\n</active_tasks>"
    end
  end

  # --- Telegram linking and subscriptions ---

  def link_telegram(task_id, bot_id, opts \\ [])
      when is_binary(task_id) and is_binary(bot_id) do
    %TaskTelegramLink{}
    |> TaskTelegramLink.changeset(%{
      task_id: task_id,
      bot_id: bot_id,
      chat_id: opts[:chat_id],
      message_id: opts[:message_id],
      notify: opts[:notify] || false,
      expect_minutes: opts[:expect_minutes]
    })
    |> Repo.insert()
  end

  def subscribe_telegram(task_id, bot_id, chat_id)
      when is_binary(task_id) and is_binary(bot_id) do
    subscribe_telegram(task_id, bot_id, chat_id, nil, [])
  end

  def subscribe_telegram(task_id, bot_id, chat_id, opts) when is_list(opts) do
    expect_minutes = Keyword.get(opts, :expect_minutes)
    subscribe_telegram(task_id, bot_id, chat_id, expect_minutes, opts)
  end

  def subscribe_telegram(task_id, bot_id, chat_id, expect_minutes)
      when is_binary(task_id) and is_binary(bot_id) do
    subscribe_telegram(task_id, bot_id, chat_id, expect_minutes, [])
  end

  def subscribe_telegram(task_id, bot_id, chat_id, expect_minutes, opts)
      when is_binary(task_id) and is_binary(bot_id) and is_list(opts) do
    message_id =
      case Keyword.get(opts, :message_id) do
        id when is_integer(id) and id > 0 -> id
        _ -> nil
      end

    existing =
      from(l in TaskTelegramLink,
        where:
          l.task_id == ^task_id and l.bot_id == ^bot_id and
            l.chat_id == ^chat_id
      )
      |> Repo.one()

    case existing do
      nil ->
        link_telegram(task_id, bot_id,
          chat_id: chat_id,
          notify: true,
          expect_minutes: expect_minutes,
          message_id: message_id
        )

      link ->
        attrs =
          %{
            notify: true,
            expect_minutes: expect_minutes
          }
          |> maybe_put_task_link_attr(:message_id, message_id)

        link
        |> Ecto.Changeset.change(attrs)
        |> Repo.update()
    end
  end

  @doc "Relays a completed Codex assistant message to subscribed Telegram chats."
  def relay_codex_message(task_id, text)
      when is_binary(task_id) and is_binary(text) do
    links =
      from(l in TaskTelegramLink,
        where:
          l.task_id == ^task_id and l.notify == true and
            not is_nil(l.chat_id)
      )
      |> Repo.all(log: false)

    text
    |> BotAdapter.split_long_text(BotAdapter.text_limit() - 16)
    |> Enum.each(fn chunk ->
      Enum.each(links, fn link ->
        result = send_codex_progress(link, chunk)

        Span.execute([:froth, :codex, :telegram_progress_relayed], nil, %{
          task_id: task_id,
          bot_id: link.bot_id,
          chat_id: link.chat_id,
          result: inspect(result, limit: 10)
        })
      end)
    end)

    :ok
  end

  defp send_codex_progress(link, chunk) do
    BotAdapter.send_blockquote(
      link.bot_id,
      link.chat_id,
      link.message_id,
      "Codex",
      chunk
    )
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  def fire_notifications(task_id) when is_binary(task_id) do
    task = get(task_id)
    if task == nil, do: throw(:task_not_found)

    links =
      from(l in TaskTelegramLink,
        where:
          l.task_id == ^task_id and l.notify == true and is_nil(l.notified_at)
      )
      |> Repo.all()

    now = DateTime.utc_now()

    for link <- links do
      if link.chat_id do
        Span.execute([:froth, :tasks, :notification_fired], nil, %{
          task_id: task_id,
          bot_id: link.bot_id,
          chat_id: link.chat_id,
          task_status: task.status
        })

        output_preview = notification_preview(task)
        message_text = build_notification_message(task, output_preview)

        synthetic_message =
          SyntheticMessage.build(link.chat_id, message_text,
            reply_to: link.message_id
          )

        Froth.Telegram.Bots.cast(
          link.bot_id,
          {:start_inference_session, synthetic_message}
        )
      end

      from(l in TaskTelegramLink, where: l.id == ^link.id)
      |> Repo.update_all(set: [notified_at: now])
    end

    :ok
  end

  def check_timeouts do
    now = DateTime.utc_now()

    links =
      from(l in TaskTelegramLink,
        join: t in Task,
        on: t.task_id == l.task_id,
        where:
          l.notify == true and
            is_nil(l.notified_at) and
            not is_nil(l.expect_minutes) and
            t.status == "running",
        where:
          fragment(
            "? + make_interval(mins => ?) < ?",
            l.inserted_at,
            l.expect_minutes,
            ^now
          ),
        select: {l, t}
      )
      |> Repo.all()

    for {link, task} <- links do
      if link.chat_id do
        elapsed = format_elapsed(task.started_at)

        message_text =
          "Task #{task.task_id} is still running after #{link.expect_minutes} minutes (elapsed: #{elapsed})."

        synthetic_message =
          SyntheticMessage.build(link.chat_id, message_text,
            reply_to: link.message_id
          )

        Froth.Telegram.Bots.cast(
          link.bot_id,
          {:start_inference_session, synthetic_message}
        )
      end

      from(l in TaskTelegramLink, where: l.id == ^link.id)
      |> Repo.update_all(set: [notified_at: now])
    end

    :ok
  end

  # --- PubSub ---

  def subscribe(task_id) when is_binary(task_id) do
    Phoenix.PubSub.subscribe(@pubsub, "task:#{task_id}")
  end

  # --- ID generation ---

  def generate_id(prefix) when is_binary(prefix) do
    hex = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    "#{prefix}:#{hex}"
  end

  # --- Private helpers ---

  defp next_sequence(task_id) do
    result =
      from(e in TaskEvent,
        where: e.task_id == ^task_id,
        select: max(e.sequence)
      )
      |> Repo.one(log: false)

    (result || 0) + 1
  end

  defp merge_metadata(task_id, updates) when is_map(updates) do
    case get(task_id) do
      nil ->
        :ok

      task ->
        merged = Map.merge(task.metadata || %{}, updates)

        from(t in Task, where: t.task_id == ^task_id)
        |> Repo.update_all(set: [metadata: merged])
    end
  end

  defp format_elapsed(nil), do: ""

  defp format_elapsed(%DateTime{} = started_at) do
    seconds = DateTime.diff(DateTime.utc_now(), started_at, :second)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    end
  end

  def recent_output_text(task_id, limit) do
    task_id
    |> recent_output_preview(limit)
    |> case do
      "" -> recent_status_text(task_id, limit)
      text -> text
    end
    |> String.slice(0, 2000)
  end

  defp recent_output_preview(task_id, limit)
       when is_binary(task_id) and is_integer(limit) do
    recent_output(task_id, limit)
    |> Enum.map_join("\n", & &1.content)
    |> String.trim()
  end

  defp recent_status_text(task_id, limit)
       when is_binary(task_id) and is_integer(limit) do
    from(e in TaskEvent,
      where:
        e.task_id == ^task_id and e.kind in ["status", "signal", "stdin"],
      order_by: [desc: e.sequence],
      limit: ^limit
    )
    |> Repo.all(log: false)
    |> Enum.reverse()
    |> Enum.map_join("\n", & &1.content)
    |> String.trim()
  end

  defp notification_preview(%Task{task_id: task_id, metadata: metadata}) do
    case recent_output_text(task_id, 10) do
      "" -> metadata["final_reply"] || metadata[:final_reply] || ""
      text -> text
    end
  end

  defp build_notification_message(
         %Task{task_id: task_id, status: status},
         output_preview
       )
       when is_binary(task_id) and is_binary(status) and
              is_binary(output_preview) do
    prefix =
      case status do
        "completed" -> "[Task completed]"
        "failed" -> "[Task failed]"
        "stopped" -> "[Task stopped]"
        other -> "[Task #{other}]"
      end

    body =
      case String.trim(output_preview) do
        "" -> ""
        preview -> "\n\n" <> preview
      end

    "#{prefix} #{task_id} #{status}.#{body}"
  end

  defp maybe_put_task_link_attr(attrs, _key, nil), do: attrs

  defp maybe_put_task_link_attr(attrs, key, value),
    do: Map.put(attrs, key, value)
end
