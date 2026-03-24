defmodule Froth.Codex.Task do
  @moduledoc """
  Fire-and-forget Codex dispatch.

  Codex is a competent member of the family. We trust it with
  architectural decisions, not just mechanical code generation.
  The workflow is: draft an RFC that describes the problem and the
  proposed architecture, then dispatch it. Codex reads the spec,
  makes judgment calls about implementation, commits the result,
  and reports the hash. We review the work, request changes if
  needed, and iterate. The RFC is the contract. The commit is the
  deliverable. The review is the conversation.

  Treat Codex as a colleague who is good at building things quickly
  and whose work you trust enough to merge after reading the diff —
  not as a code monkey who needs every function signature dictated.
  High-level intent in, working code out. If the RFC is clear, the
  code will be clear.

  Starts a Codex session, sends a prompt, streams entries to PubSub,
  and sends a Telegram message with a "Micromanage" button linking
  to the Codex LiveView.

  ## Usage

      Froth.Codex.Task.run("fix the bug in lib/froth/podcast.ex",
        cwd: "/path/to/project",
        chat_id: chat_id
      )

      Froth.Codex.Task.dispatch("rfc/froth-rfc0007.md",
        chat_id: chat_id
      )
  """

  alias Froth.Telemetry.Span
  alias Froth.Codex.Session, as: CodexSession
  alias Froth.Codex.TaskWatcher
  alias Froth.Telegram.BotAdapter

  @base_url "https://t.me/charliebuddybot/tool?startapp="

  @doc """
  Start a Codex task. Returns `{:ok, session_id}`.

  Options:
    * `:cwd` — working directory for Codex (default: ~/froth)
    * `:chat_id` — Telegram chat to send the "Micromanage" button to
    * `:bot_id` — Telegram bot id to notify when the Codex task finishes
    * `:reply_to` — message ID to reply to
    * `:session_id` — explicit session ID (default: generated)
    * `:await` — if true, blocks until turn completes (default: false)
  """
  def run(prompt, opts \\ []) when is_binary(prompt) do
    session_module = Keyword.get(opts, :session_module, CodexSession)

    session_id =
      Keyword.get(opts, :session_id) ||
        "codex_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

    cwd = Keyword.get(opts, :cwd, Path.join(System.user_home!(), "froth"))
    chat_id = Keyword.get(opts, :chat_id)
    bot_id = Keyword.get(opts, :bot_id)
    reply_to = Keyword.get(opts, :reply_to)
    await = Keyword.get(opts, :await, false)

    with {:ok, _pid} <- session_module.ensure_started(session_id, cwd: cwd),
         {:ok, task} <- create_codex_task(session_id, prompt, cwd) do
      case maybe_subscribe_telegram(task.task_id, bot_id, chat_id) do
        :ok ->
          case start_task_watcher(task.task_id, session_id, session_module) do
            {:ok, watcher_pid} ->
              case session_module.send_prompt(session_id, prompt) do
                :ok ->
                  Froth.Tasks.start(task.task_id)

                  if chat_id do
                    send_micromanage_button(session_id, chat_id, reply_to, prompt)
                  end

                  Span.execute([:froth, :codex, :task_started], nil, %{
                    session_id: session_id,
                    task_id: task.task_id,
                    prompt: prompt
                  })

                  if await do
                    case session_module.subscribe(session_id) do
                      :ok ->
                        initial_saw_turn? = await_active_turn?(session_id, session_module)
                        collect_until_done(session_id, session_module, initial_saw_turn?)

                      {:error, reason} ->
                        {:error, reason}
                    end
                  else
                    {:ok, session_id}
                  end

                {:error, reason} = error ->
                  stop_watcher(watcher_pid)
                  Froth.Tasks.fail(task.task_id, task_failure_reason(reason))
                  error
              end

            {:error, reason} = error ->
              Froth.Tasks.fail(task.task_id, task_failure_reason(reason))
              error
          end

        {:error, reason} = error ->
          Froth.Tasks.fail(task.task_id, task_failure_reason(reason))
          error
      end
    end
  end

  @doc """
  Dispatch an RFC to Codex for implementation.

  Reads the RFC file, constructs a prompt that tells Codex to implement
  the spec, commit when done, and report the commit hash. Returns
  `{:ok, session_id}`.

  The commit hash appears in the Codex session output. Charlie can
  investigate the result however he feels like.

  Options: same as `run/2`.
  """
  def dispatch(rfc_path, opts \\ []) when is_binary(rfc_path) do
    cwd = Keyword.get(opts, :cwd, Path.join(System.user_home!(), "froth"))
    full_path = Path.expand(rfc_path, cwd)

    case File.read(full_path) do
      {:ok, content} ->
        prompt = """
        Implement the following RFC. Read it carefully, then write the code.
        When you are done, commit all changes with a descriptive message
        that references the RFC number. After committing, print the commit
        hash on a line by itself prefixed with COMMIT: so it can be parsed.

        File: #{rfc_path}

        ---
        #{content}
        ---

        Work in #{cwd}. Do not ask clarifying questions. If the RFC is
        ambiguous, make the simplest choice that satisfies the spec.
        Commit when done. Print the commit hash.
        """

        run(prompt, Keyword.put(opts, :cwd, cwd))

      {:error, reason} ->
        {:error, {:file_read_failed, full_path, reason}}
    end
  end

  @doc "Get the LiveView URL for a Codex session."
  def url(session_id), do: "#{@base_url}#{session_id}"

  defp send_micromanage_button(session_id, chat_id, reply_to, prompt) do
    truncated =
      if String.length(prompt) > 100,
        do: String.slice(prompt, 0, 97) <> "...",
        else: prompt

    text = "Hiring subcontractor: #{truncated}"

    buttons = [
      [
        %{
          "@type" => "inlineKeyboardButton",
          "text" => "Micromanage",
          "type" => %{
            "@type" => "inlineKeyboardButtonTypeUrl",
            "url" => url(session_id)
          }
        }
      ]
    ]

    BotAdapter.send_message("charlie", chat_id, text,
      reply_to: reply_to,
      reply_markup: %{
        "@type" => "replyMarkupInlineKeyboard",
        "rows" => buttons
      }
    )
  end

  defp collect_until_done(session_id, session_module, saw_turn?) do
    receive do
      {:codex_session_updated, ^session_id} ->
        case session_module.snapshot(session_id) do
          {:ok, %{status: :error}} ->
            {:error, session_id}

          {:ok, snapshot} ->
            active_turn_id =
              Map.get(snapshot, :active_turn_id) || Map.get(snapshot, "active_turn_id")

            saw_turn? = saw_turn? or is_binary(active_turn_id)

            if saw_turn? and is_nil(active_turn_id) do
              {:ok, session_id}
            else
              collect_until_done(session_id, session_module, saw_turn?)
            end

          _other ->
            collect_until_done(session_id, session_module, saw_turn?)
        end
    after
      300_000 -> {:timeout, session_id}
    end
  end

  defp create_codex_task(session_id, prompt, cwd) do
    Froth.Tasks.create(%{
      task_id: Froth.Tasks.generate_id("codex"),
      type: "codex",
      label: prompt_label(prompt),
      metadata: %{session_id: session_id, cwd: cwd}
    })
  end

  defp maybe_subscribe_telegram(task_id, bot_id, chat_id)
       when is_binary(task_id) and is_binary(bot_id) and is_integer(chat_id) do
    case Froth.Tasks.subscribe_telegram(task_id, bot_id, chat_id) do
      {:ok, _link} -> :ok
      {:error, _reason} = error -> error
      _ -> :ok
    end
  end

  defp maybe_subscribe_telegram(_task_id, _bot_id, _chat_id), do: :ok

  defp start_task_watcher(task_id, session_id, session_module)
       when is_binary(task_id) and is_binary(session_id) do
    DynamicSupervisor.start_child(
      Froth.Tasks.Supervisor,
      {TaskWatcher, [task_id: task_id, session_id: session_id, session_module: session_module]}
    )
  end

  defp stop_watcher(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp await_active_turn?(session_id, session_module) do
    case session_module.snapshot(session_id) do
      {:ok, snapshot} ->
        active_turn_id = Map.get(snapshot, :active_turn_id) || Map.get(snapshot, "active_turn_id")
        is_binary(active_turn_id)

      _ ->
        false
    end
  end

  defp prompt_label(prompt) when is_binary(prompt) do
    prompt
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> "Codex task"
      compact -> String.slice(compact, 0, 120)
    end
  end

  defp task_failure_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 200)

  defp task_failure_reason(reason) do
    reason
    |> inspect()
    |> String.slice(0, 200)
  end
end
