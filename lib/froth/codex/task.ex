defmodule Froth.Codex.Task do
  @moduledoc """
  Fire-and-forget Codex subcontractor.

  Starts a Codex session, sends a prompt, streams entries to PubSub,
  and sends a Telegram message with a "Micromanage" button linking
  to the Codex LiveView.

  ## Usage

      Froth.Codex.Task.run("fix the bug in lib/froth/podcast.ex",
        cwd: "/path/to/project",
        chat_id: chat_id
      )
  """

  require Logger

  alias Froth.Codex.Session, as: CodexSession
  alias Froth.Telegram.BotAdapter

  @base_url "https://t.me/charliebuddybot/tool?startapp="

  @doc """
  Start a Codex task. Returns `{:ok, session_id}`.

  Options:
    * `:cwd` — working directory for Codex (default: ~/froth)
    * `:chat_id` — Telegram chat to send the "Micromanage" button to
    * `:reply_to` — message ID to reply to
    * `:session_id` — explicit session ID (default: generated)
    * `:await` — if true, blocks until turn completes (default: false)
  """
  def run(prompt, opts \\ []) when is_binary(prompt) do
    session_id =
      Keyword.get(opts, :session_id) ||
        "codex_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

    cwd = Keyword.get(opts, :cwd, Path.join(System.user_home!(), "froth"))
    chat_id = Keyword.get(opts, :chat_id)
    reply_to = Keyword.get(opts, :reply_to)
    await = Keyword.get(opts, :await, false)

    # Start the Codex session (spawns the app-server port)
    {:ok, _pid} = CodexSession.ensure_started(session_id, cwd: cwd)

    # Send Telegram button if chat_id given
    if chat_id do
      send_micromanage_button(session_id, chat_id, reply_to, prompt)
    end

    # Send the prompt to Codex
    :ok = CodexSession.send_prompt(session_id, prompt)

    Logger.info(event: :codex_task_started, session_id: session_id, prompt: prompt)

    if await do
      CodexSession.subscribe(session_id)
      collect_until_done(session_id)
    else
      {:ok, session_id}
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

  defp collect_until_done(session_id) do
    receive do
      {:codex_session_updated, ^session_id} ->
        case CodexSession.snapshot(session_id) do
          {:ok, %{status: :idle}} ->
            {:ok, session_id}

          {:ok, %{status: :error}} ->
            {:error, session_id}

          _ ->
            collect_until_done(session_id)
        end
    after
      300_000 -> {:timeout, session_id}
    end
  end
end
