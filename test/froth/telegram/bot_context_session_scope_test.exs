defmodule Froth.Telegram.BotContextSessionScopeTest do
  use ExUnit.Case, async: true

  alias Froth.Repo
  alias Froth.Telegram.BotContext
  alias Froth.Telegram.Message, as: TelegramMessage
  alias Froth.Telegram.SessionConfig

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "render_parts uses only the requested telegram session's recent messages" do
    chat_id = unique_chat_id()
    ensure_session("charlie")
    ensure_session("mbrockman")

    insert_telegram_message(
      "charlie",
      chat_id,
      101,
      7,
      1_700_000_100,
      "charlie only older"
    )

    insert_telegram_message(
      "mbrockman",
      chat_id,
      201,
      8,
      1_700_000_200,
      "mbrockman only newer"
    )

    insert_telegram_message(
      "charlie",
      chat_id,
      102,
      7,
      1_700_000_300,
      "charlie only newest"
    )

    prompt =
      chat_id
      |> BotContext.render_parts(
        telegram_session_id: "charlie",
        recent_message_limit: 10
      )
      |> Enum.join("\n")

    assert prompt =~ "charlie only older"
    assert prompt =~ "charlie only newest"
    refute prompt =~ "mbrockman only newer"
  end

  test "recent_message_limit is applied within the requested telegram session" do
    chat_id = unique_chat_id()
    ensure_session("charlie")
    ensure_session("mbrockman")

    insert_telegram_message(
      "charlie",
      chat_id,
      101,
      7,
      1_700_000_100,
      "charlie oldest"
    )

    insert_telegram_message(
      "charlie",
      chat_id,
      102,
      7,
      1_700_000_200,
      "charlie middle"
    )

    insert_telegram_message(
      "mbrockman",
      chat_id,
      201,
      8,
      1_700_000_250,
      "mbrockman interloper"
    )

    insert_telegram_message(
      "charlie",
      chat_id,
      103,
      7,
      1_700_000_300,
      "charlie newest"
    )

    insert_telegram_message(
      "mbrockman",
      chat_id,
      202,
      8,
      1_700_000_350,
      "mbrockman latest"
    )

    prompt =
      chat_id
      |> BotContext.render_parts(
        telegram_session_id: "charlie",
        recent_message_limit: 2
      )
      |> Enum.join("\n")

    refute prompt =~ "charlie oldest"
    assert prompt =~ "charlie middle"
    assert prompt =~ "charlie newest"
    refute prompt =~ "mbrockman interloper"
    refute prompt =~ "mbrockman latest"
  end

  test "group chats prefer the enabled user session over the configured bot session" do
    chat_id = unique_group_chat_id()
    ensure_session("charlie")
    ensure_user_session("mbrockman")

    insert_telegram_message(
      "charlie",
      chat_id,
      101,
      7,
      1_700_000_100,
      "charlie group view"
    )

    insert_telegram_message(
      "mbrockman",
      chat_id,
      201,
      8,
      1_700_000_200,
      "user session group view"
    )

    prompt =
      chat_id
      |> BotContext.render_parts(
        telegram_session_id: "charlie",
        recent_message_limit: 10
      )
      |> Enum.join("\n")

    assert prompt =~ "user session group view"
    refute prompt =~ "charlie group view"
  end

  defp ensure_session(session_id) do
    case Repo.get(SessionConfig, session_id) do
      nil ->
        Repo.insert!(
          SessionConfig.changeset(%SessionConfig{}, %{
            id: session_id,
            api_id: 1234,
            api_hash: "test-hash",
            bot_token: "test-token",
            enabled: true
          })
        )

      _session ->
        :ok
    end
  end

  defp ensure_user_session(session_id) do
    case Repo.get(SessionConfig, session_id) do
      nil ->
        Repo.insert!(
          SessionConfig.changeset(%SessionConfig{}, %{
            id: session_id,
            api_id: 1234,
            api_hash: "test-hash",
            phone_number: "+15551234567",
            enabled: true
          })
        )

      _session ->
        :ok
    end
  end

  defp insert_telegram_message(
         session_id,
         chat_id,
         message_id,
         sender_id,
         date,
         text
       ) do
    Repo.insert!(
      TelegramMessage.changeset(%TelegramMessage{}, %{
        telegram_session_id: session_id,
        chat_id: chat_id,
        message_id: message_id,
        sender_id: sender_id,
        date: date,
        raw: %{
          "content" => %{
            "@type" => "messageText",
            "text" => %{"text" => text}
          }
        }
      })
    )
  end

  defp unique_chat_id do
    9_200_000_000 + System.unique_integer([:positive])
  end

  defp unique_group_chat_id do
    -9_200_000_000 - System.unique_integer([:positive])
  end
end
