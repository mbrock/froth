defmodule Froth.HeadlinesTest do
  use ExUnit.Case, async: false

  alias Froth.ChatSummary
  alias Froth.Headlines
  alias Froth.Inference.Tools
  alias Froth.LLM.Message, as: LLMMessage
  alias Froth.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "extract builds the summary prompt and passes the expected tools to adhoc" do
    test_pid = self()
    previous_fun = Application.get_env(:froth, :llm_stream_single_fun)
    chat_id = unique_chat_id()

    insert_summary(chat_id, ~D[2026-03-20], "The group launched a new project.")
    insert_summary(chat_id, ~D[2026-03-21], "A long debugging session fixed the outage.")

    on_exit(fn ->
      if previous_fun do
        Application.put_env(:froth, :llm_stream_single_fun, previous_fun)
      else
        Application.delete_env(:froth, :llm_stream_single_fun)
      end
    end)

    Application.put_env(:froth, :llm_stream_single_fun, fn api_messages, _on_event, opts ->
      send(test_pid, {:llm_call, api_messages, opts})

      {:ok,
       %{
         text: "done",
         content: [%{"type" => "text", "text" => "done"}],
         stop_reason: "stop",
         usage: %{},
         model: opts[:model],
         message_id: "msg_headlines_1"
       }}
    end)

    {_cycle, output} = Headlines.extract(~D[2026-03-22], chat_id: chat_id)

    assert output == "done"
    assert_receive {:llm_call, api_messages, opts}, 5_000

    assert [
             %LLMMessage{
               role: :user,
               content: [%{"type" => "text", "text" => prompt}]
             }
           ] = api_messages

    assert prompt =~ ~s(<summary date="2026-03-20">)
    assert prompt =~ "The group launched a new project."
    assert prompt =~ ~s(<summary date="2026-03-21">)
    assert prompt =~ "A long debugging session fixed the outage."
    assert prompt =~ "Extract the most significant and memorable events from 2026-03-22."
    assert prompt =~ "call register_headlines exactly once with date=2026-03-22"

    assert opts[:provider] == :openai
    assert opts[:model] == "gpt-5.4"
    assert Enum.map(opts[:tools], & &1["name"]) == ["read_log", "search", "register_headlines"]
  end

  test "register_headlines emits telemetry and formats a chat message" do
    test_pid = self()
    handler_id = "headlines-test-#{System.unique_integer([:positive])}"
    chat_id = unique_chat_id()

    :telemetry.attach(
      handler_id,
      [:froth, :headlines, :registered],
      fn event_name, measurements, metadata, pid ->
        send(pid, {:telemetry, event_name, measurements, metadata})
      end,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, "Registered 2 headlines for 2026-03-22"} =
             Tools.execute(
               "register_headlines",
               %{
                 "date" => "2026-03-22",
                 "headlines" => [
                   %{
                     "title" => "Launch day",
                     "sentence" => "The team rolled out the feature to production."
                   },
                   %{
                     "title" => "Outage resolved",
                     "sentence" => "A late-night fix restored the broken sync job."
                   }
                 ]
               },
               chat_id,
               session_id: "charlie",
               send_message_fun: fn session_id, sent_chat_id, text, opts ->
                 send(test_pid, {:sent_message, session_id, sent_chat_id, text, opts})
                 {:ok, %{"id" => 1}}
               end
             )

    assert_receive {:telemetry, [:froth, :headlines, :registered], %{count: 2}, metadata}, 5_000
    assert metadata[:date] == "2026-03-22"
    assert length(metadata[:headlines]) == 2

    assert_receive {:sent_message, "charlie", ^chat_id, text, opts}, 5_000

    assert text ==
             "2026-03-22\n\n" <>
               "Launch day — The team rolled out the feature to production.\n" <>
               "Outage resolved — A late-night fix restored the broken sync job."

    assert length(opts[:entities]) == 3
    assert Enum.all?(opts[:entities], &(get_in(&1, ["type", "@type"]) == "textEntityTypeBold"))
    assert [:froth, :headlines, :registered] in Froth.Telemetry.events()
  end

  defp insert_summary(chat_id, date, text) do
    from_unix = DateTime.new!(date, ~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
    to_unix = DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()

    %ChatSummary{}
    |> ChatSummary.changeset(%{
      chat_id: chat_id,
      from_date: from_unix,
      to_date: to_unix,
      agent: "claude-opus-4-6",
      summary_text: text,
      message_count: 1
    })
    |> Repo.insert!()
  end

  defp unique_chat_id do
    9_100_000_000 + System.unique_integer([:positive])
  end
end
