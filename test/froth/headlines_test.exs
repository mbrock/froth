defmodule Froth.HeadlinesTest do
  use Froth.TelegramBotCase, async: true

  import Ecto.Query

  alias Froth.Agent.Message, as: AgentMessage
  alias Froth.ChatSummary
  alias Froth.Event
  alias Froth.Headlines
  alias Froth.Inference.Tools
  alias Froth.LLM.Message, as: LLMMessage
  alias Froth.LLM.Request

  test "extract builds the summary prompt and passes the expected tools to adhoc" do
    chat_id = unique_chat_id()
    model = FakeLLM.claim()

    insert_summary(
      chat_id,
      ~D[2026-03-20],
      "The group launched a new project."
    )

    insert_summary(
      chat_id,
      ~D[2026-03-21],
      "A long debugging session fixed the outage."
    )

    %Event{}
    |> Event.changeset(%{
      event: "froth.headlines.registered",
      metadata: %{
        "date" => "2026-03-19",
        "chat_id" => Integer.to_string(chat_id),
        "headlines" => [
          %{
            "emoji" => "📰",
            "title" => "Old scandal",
            "sentence" => "An earlier headline was already filed.",
            "from_time" => "2026-03-19T08:00:00Z",
            "to_time" => "2026-03-19T08:30:00Z"
          }
        ]
      },
      measurements: %{"count" => 1}
    })
    |> Repo.insert!()

    %{bot: bot} = start_charlie_bot()

    extract_task =
      Task.async(fn ->
        Headlines.extract(
          bot: bot,
          chat_id: chat_id,
          provider: :fakeai,
          model: model
        )
      end)

    {from, request} = receive_headlines_llm_request()

    assert [
             %LLMMessage{
               role: :user,
               content: [%{"type" => "text", "text" => prompt}]
             }
           ] = request.messages

    assert prompt =~ ~s(<summary date="2026-03-20">)
    assert prompt =~ "The group launched a new project."
    assert prompt =~ ~s(<summary date="2026-03-21">)
    assert prompt =~ "A long debugging session fixed the outage."
    assert prompt =~ "<existing_headlines>"
    assert prompt =~ ~s(<headlines date="2026-03-19">)
    assert prompt =~ "<emoji>📰</emoji>"
    assert prompt =~ "Old scandal"

    assert prompt =~ "<objective>"

    assert prompt =~
             "Write tabloid headlines for EVERY summary date in the context."

    assert prompt =~
             "Existing registered headlines are included below in XML. Those days are already done."

    assert prompt =~
             "Recurring automated events (scheduled scans, hourly podcasts, Tototo sleeping) are NOT headlines unless something broke or changed."

    assert prompt =~
             "A day can have multiple real headlines. If a day has several distinct developments, register all of them together."

    assert prompt =~
             "Do not stop at one headline for a day unless that day truly has only one substantial development worth remembering."

    assert prompt =~
             "Before you register a date, make sure you have the complete set of worthy headlines for that day, not just the first good one you found."

    assert prompt =~
             "Only include items that are genuinely worth headlining, but include ALL of them once they clear that bar."

    assert prompt =~
             "Use timeline to investigate details and find an approximate UTC time range for each headline before registering it."

    assert prompt =~
             "Omit query to browse a date window. Add query plus before/after when you need targeted phrase search with surrounding context."

    assert prompt =~
             "Prefer focused queries and narrow date windows. Avoid repeatedly pulling large spans once you already have enough evidence for that day."

    assert prompt =~
             "You do not need to finish all research before you start registering. As soon as one day is sufficiently researched and complete, call register_headlines for that day and then continue to the next unfinished day."

    assert prompt =~
             "After you register a date, stop researching that date unless you uncover a clear miss."

    assert prompt =~
             "Each headline must include from_time and to_time as ISO 8601 UTC datetime strings bracketing when the event happened."

    assert prompt =~ "You may register headlines in any order."

    assert prompt =~ "Call register_headlines once per date."

    assert prompt =~
             "When you register a day, include the full set of worthy headlines for that day in a single register_headlines call."

    assert prompt =~
             "In the register_headlines arguments, the headlines array is the complete deliverable for that date. Put EVERY headline worth keeping for that date into that array."

    assert prompt =~ "Do not submit a representative sample."

    assert prompt =~
             "A headlines array of length 1 is only correct when that date truly has exactly one worthy headline after investigation."

    assert prompt =~
             "The tool response will tell you what's left, so keep going until every available summary date is done."

    assert request.model == model
    assert request.system == "You are a tabloid editor."
    assert request.provider_options["reasoning_effort"] == "medium"
    assert request.provider_options["reasoning_summary"] == "auto"

    assert Enum.map(request.tools, & &1["name"]) == [
             "timeline",
             "register_headlines"
           ]

    register_headlines_tool =
      Enum.find(request.tools, &(&1["name"] == "register_headlines"))

    assert get_in(register_headlines_tool, [
             "input_schema",
             "properties",
             "headlines",
             "items",
             "required"
           ]) == ["emoji", "title", "sentence", "from_time", "to_time"]

    FakeLLM.reply(from, {:ok, text_response("done")})

    {_cycle, output} = Task.await(extract_task, 10_000)
    assert output == "done"
  end

  test "extract_all builds the multi-day prompt" do
    chat_id = unique_chat_id()
    model = FakeLLM.claim()

    insert_summary(
      chat_id,
      ~D[2026-03-20],
      "The group launched a new project."
    )

    insert_summary(
      chat_id,
      ~D[2026-03-21],
      "A long debugging session fixed the outage."
    )

    %{bot: bot} = start_charlie_bot()

    extract_task =
      Task.async(fn ->
        Headlines.extract_all(
          bot: bot,
          chat_id: chat_id,
          provider: :fakeai,
          model: model
        )
      end)

    {from, request} = receive_headlines_llm_request()

    assert [
             %LLMMessage{
               role: :user,
               content: [%{"type" => "text", "text" => prompt}]
             }
           ] = request.messages

    assert prompt =~
             "Write tabloid headlines for EVERY summary date in the context."

    assert prompt =~ "You may register headlines in any order."

    assert prompt =~
             "A day can have multiple real headlines. If a day has several distinct developments, register all of them together."

    assert prompt =~
             "Do not stop at one headline for a day unless that day truly has only one substantial development worth remembering."

    assert prompt =~
             "Before you register a date, make sure you have the complete set of worthy headlines for that day, not just the first good one you found."

    assert prompt =~
             "Only include items that are genuinely worth headlining, but include ALL of them once they clear that bar."

    assert prompt =~
             "Prefer focused queries and narrow date windows. Avoid repeatedly pulling large spans once you already have enough evidence for that day."

    assert prompt =~
             "You do not need to finish all research before you start registering. As soon as one day is sufficiently researched and complete, call register_headlines for that day and then continue to the next unfinished day."

    assert prompt =~
             "In the register_headlines arguments, the headlines array is the complete deliverable for that date. Put EVERY headline worth keeping for that date into that array."

    assert prompt =~
             "The tool response will tell you what's left, so keep going until every available summary date is done."

    FakeLLM.reply(from, {:ok, text_response("done")})

    {_cycle, output} = Task.await(extract_task, 10_000)
    assert output == "done"
  end

  test "start streams deltas and the final agent message" do
    chat_id = unique_chat_id()
    model = FakeLLM.claim()

    insert_summary(
      chat_id,
      ~D[2026-03-20],
      "The group launched a new project."
    )

    %{bot: bot} = start_charlie_bot()

    {cycle, stream} =
      Headlines.start(
        bot: bot,
        chat_id: chat_id,
        provider: :fakeai,
        model: model
      )

    collector = Task.async(fn -> Enum.to_list(stream) end)

    assert is_binary(cycle.id)

    {from, request} = receive_headlines_llm_request()
    assert request.model == model
    assert request.provider_options["reasoning_summary"] == "auto"

    FakeLLM.emit(from, {:thinking_delta, %{"delta" => "thinking..."}})
    FakeLLM.emit(from, {:thinking_stop, %{}})
    FakeLLM.emit(from, {:text_delta, "done"})
    FakeLLM.reply(from, {:ok, text_response("done")})

    items = Task.await(collector, 10_000)

    assert {:stream, {:thinking_delta, %{"delta" => "thinking..."}}} in items
    assert {:stream, {:thinking_stop, %{}}} in items
    assert {:stream, {:text_delta, "done"}} in items

    assert Enum.any?(items, fn
             {:event, _event, %AgentMessage{role: :agent} = message} ->
               AgentMessage.extract_text(message) == "done"

             _ ->
               false
           end)
  end

  test "register_headlines emits telemetry, formats the chat message, and reports progress" do
    test_pid = self()
    handler_id = "headlines-test-#{System.unique_integer([:positive])}"
    chat_id = unique_chat_id()

    insert_summary(chat_id, ~D[2026-03-20], "An earlier scandal.")
    insert_summary(chat_id, ~D[2026-03-21], "A middle scandal.")
    insert_summary(chat_id, ~D[2026-03-22], "A fresh scandal.")

    %Event{}
    |> Event.changeset(%{
      event: "froth.headlines.registered",
      metadata: %{
        "date" => "2026-03-20",
        "chat_id" => Integer.to_string(chat_id),
        "headlines" => []
      },
      measurements: %{"count" => 0}
    })
    |> Repo.insert!()

    %Event{}
    |> Event.changeset(%{
      event: "froth.headlines.registered",
      metadata: %{"date" => "2026-03-21", "headlines" => []},
      measurements: %{"count" => 0}
    })
    |> Repo.insert!()

    :telemetry.attach(
      handler_id,
      [:froth, :headlines, :registered],
      fn event_name, measurements, metadata, pid ->
        send(pid, {:telemetry, event_name, measurements, metadata})
      end,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, [%Froth.Context.Block{} = block]} =
             Tools.execute(
               "register_headlines",
               %{
                 "date" => "2026-03-22",
                 "headlines" => [
                   %{
                     "emoji" => "🚀",
                     "title" => "Launch day",
                     "sentence" =>
                       "The team rolled out the feature to production.",
                     "from_time" => "2026-03-22T09:00:00Z",
                     "to_time" => "2026-03-22T09:45:00Z"
                   },
                   %{
                     "emoji" => "🛠️",
                     "title" => "Outage resolved",
                     "sentence" =>
                       "A late-night fix restored the broken sync job.",
                     "from_time" => "2026-03-22T22:15:00Z",
                     "to_time" => "2026-03-22T23:05:00Z"
                   }
                 ]
               },
               chat_id,
               session_id: "charlie",
               bot_id: "charlie",
               bot_username: "charliebuddybot",
               cycle_id: "cycle-123",
               send_message_fun: fn session_id, sent_chat_id, text, opts ->
                 send(
                   test_pid,
                   {:sent_message, session_id, sent_chat_id, text, opts}
                 )

                 {:ok, %{"id" => 1}}
               end
             )

    assert Froth.Context.Block.attr(block, :kind) == "headlines_registered"
    assert Froth.Context.Block.attr(block, :date) == "2026-03-22"
    assert Froth.Context.Block.attr(block, :count) == 2
    assert Froth.Context.Block.attr(block, :next_unfinished) == "2026-03-21"

    assert_receive {:telemetry, [:froth, :headlines, :registered],
                    %{count: 2}, metadata},
                   5_000

    assert metadata[:date] == "2026-03-22"
    assert metadata[:chat_id] == chat_id
    assert length(metadata[:headlines]) == 2

    assert_receive {:sent_message, "charlie", ^chat_id, text, opts}, 5_000

    assert text ==
             "2026-03-22\n\n" <>
               "🚀 Launch day (09:00-09:45 UTC)\n\n" <>
               "🛠️ Outage resolved (22:15-23:05 UTC)"

    assert length(opts[:entities]) == 3

    assert Enum.all?(
             opts[:entities],
             &(get_in(&1, ["type", "@type"]) == "textEntityTypeBold")
           )

    [date_entity, first_headline_entity, second_headline_entity] =
      opts[:entities]

    assert date_entity["offset"] == 0
    assert date_entity["length"] == utf16_length("2026-03-22")

    assert first_headline_entity["offset"] == utf16_length("2026-03-22\n\n🚀 ")
    assert first_headline_entity["length"] == utf16_length("Launch day")

    assert second_headline_entity["offset"] ==
             utf16_length(
               "2026-03-22\n\n🚀 Launch day (09:00-09:45 UTC)\n\n🛠️ "
             )

    assert second_headline_entity["length"] == utf16_length("Outage resolved")

    assert get_in(opts[:reply_markup], [
             "rows",
             Access.at(0),
             Access.at(0),
             "text"
           ]) == "Open"

    assert get_in(opts[:reply_markup], [
             "rows",
             Access.at(0),
             Access.at(0),
             "type",
             "url"
           ]) ==
             "https://t.me/charliebuddybot/tool?startapp=cycle_charlie_cycle-123"

    assert [:froth, :headlines, :registered] in Froth.Telemetry.events()
  end

  test "register_headlines progress accumulates across successive registrations" do
    chat_id = unique_chat_id()

    insert_summary(chat_id, ~D[2026-03-20], "An earlier scandal.")
    insert_summary(chat_id, ~D[2026-03-21], "A middle scandal.")
    insert_summary(chat_id, ~D[2026-03-22], "A fresh scandal.")

    assert {:ok, [%Froth.Context.Block{} = block1]} =
             Tools.execute(
               "register_headlines",
               %{
                 "date" => "2026-03-20",
                 "headlines" => [
                   %{
                     "emoji" => "1️⃣",
                     "title" => "Day one",
                     "sentence" => "The first scandal landed.",
                     "from_time" => "2026-03-20T09:00:00Z",
                     "to_time" => "2026-03-20T09:30:00Z"
                   }
                 ]
               },
               chat_id,
               session_id: "charlie",
               send_message_fun: fn _session_id, _chat_id, _text, _opts ->
                 {:ok, %{"id" => 1}}
               end
             )

    assert Froth.Context.Block.attr(block1, :date) == "2026-03-20"
    assert Froth.Context.Block.attr(block1, :done_days) == 1
    assert Froth.Context.Block.attr(block1, :total_days) == 3
    assert Froth.Context.Block.attr(block1, :next_unfinished) == "2026-03-21"

    assert {:ok, [%Froth.Context.Block{} = block2]} =
             Tools.execute(
               "register_headlines",
               %{
                 "date" => "2026-03-21",
                 "headlines" => [
                   %{
                     "emoji" => "2️⃣",
                     "title" => "Day two",
                     "sentence" => "The second scandal followed.",
                     "from_time" => "2026-03-21T10:00:00Z",
                     "to_time" => "2026-03-21T10:45:00Z"
                   }
                 ]
               },
               chat_id,
               session_id: "charlie",
               send_message_fun: fn _session_id, _chat_id, _text, _opts ->
                 {:ok, %{"id" => 1}}
               end
             )

    assert Froth.Context.Block.attr(block2, :date) == "2026-03-21"
    assert Froth.Context.Block.attr(block2, :done_days) == 2
    assert Froth.Context.Block.attr(block2, :next_unfinished) == "2026-03-22"
  end

  test "register_headlines can skip Telegram sending while still recording progress" do
    chat_id = unique_chat_id()

    insert_summary(chat_id, ~D[2026-03-20], "An earlier scandal.")
    insert_summary(chat_id, ~D[2026-03-21], "A middle scandal.")

    assert {:ok, [%Froth.Context.Block{} = block]} =
             Tools.execute(
               "register_headlines",
               %{
                 "date" => "2026-03-20",
                 "headlines" => [
                   %{
                     "emoji" => "🧪",
                     "title" => "Dry run",
                     "sentence" =>
                       "The headline was recorded without posting to Telegram.",
                     "from_time" => "2026-03-20T09:00:00Z",
                     "to_time" => "2026-03-20T09:15:00Z"
                   }
                 ]
               },
               chat_id,
               session_id: "charlie",
               spam: false,
               send_message_fun: fn _session_id, _chat_id, _text, _opts ->
                 send(self(), :sent_message)
                 {:ok, %{"id" => 1}}
               end
             )

    assert Froth.Context.Block.attr(block, :done_days) == 1
    assert Froth.Context.Block.attr(block, :total_days) == 2

    refute_receive :sent_message

    assert [%Event{metadata: metadata}] =
             Repo.all(
               from(e in Event,
                 where:
                   e.event == "froth.headlines.registered" and
                     fragment(
                       "?->>'chat_id' = ?",
                       e.metadata,
                       ^Integer.to_string(chat_id)
                     ),
                 order_by: [desc: e.inserted_at]
               ),
               log: false
             )

    assert metadata["date"] == "2026-03-20"
    assert get_in(metadata, ["headlines", Access.at(0), "title"]) == "Dry run"
  end

  defp insert_summary(chat_id, date, text) do
    from_unix =
      DateTime.new!(date, ~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()

    to_unix =
      DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")
      |> DateTime.to_unix()

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

  defp text_response(text) do
    %{
      text: text,
      content: [%{"type" => "text", "text" => text}],
      stop_reason: "stop"
    }
  end

  # Returns `{from, request}` for the first LLM call whose request
  # matches the tabloid-editor shape. Skips (and discards) any calls
  # that don't match — this is useful because `Headlines.extract/1`
  # spawns a charlie bot context whose unrelated subsystems may also
  # issue LLM requests.
  defp receive_headlines_llm_request(timeout \\ 5_000)
       when is_integer(timeout) and timeout > 0 do
    deadline_ms = System.monotonic_time(:millisecond) + timeout
    do_receive_headlines_llm_request(deadline_ms)
  end

  defp do_receive_headlines_llm_request(deadline_ms)
       when is_integer(deadline_ms) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {Froth.LLM.Fake, from, %Request{} = request} ->
        if headlines_request?(request) do
          {from, request}
        else
          do_receive_headlines_llm_request(deadline_ms)
        end
    after
      remaining_ms ->
        flunk("expected tabloid editor LLM call")
    end
  end

  defp headlines_request?(%Request{system: system, tools: tools}) do
    system == "You are a tabloid editor." and
      Enum.map(tools || [], & &1["name"]) == [
        "timeline",
        "register_headlines"
      ]
  end

  defp utf16_length(text) when is_binary(text) do
    text
    |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
    |> byte_size()
    |> div(2)
  end
end
