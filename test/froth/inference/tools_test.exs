defmodule Froth.Inference.ToolsTest do
  use Froth.TelegramBotCase, async: true

  alias Froth.Analysis
  alias Froth.ChatSummary
  alias Froth.Agent.{Cycle, CycleRuntime}
  alias Froth.Context.Block
  alias Froth.Inference.Tools
  alias LLM.Message, as: LLMMessage
  alias LLM.Request
  alias Froth.Task
  alias Froth.Telegram.CycleLink
  alias Froth.Telegram.Message, as: TelegramMessage
  alias Froth.Telegram.PendingAsk
  alias Froth.Telegram.SessionConfig
  alias Froth.Telegram.Username

  test "fetch is exposed in tool specs" do
    spec = Enum.find(Tools.specs_for_api(), &(&1["name"] == "fetch"))

    refute is_nil(spec)
    assert get_in(spec, ["input_schema", "required"]) == ["source"]

    assert get_in(spec, ["input_schema", "properties", "source", "type"]) ==
             "string"

    assert get_in(spec, ["input_schema", "properties", "view", "type"]) ==
             "boolean"
  end

  test "timeline is exposed in tool specs" do
    spec = Enum.find(Tools.specs_for_api(), &(&1["name"] == "timeline"))

    refute is_nil(spec)

    assert get_in(spec, ["input_schema", "properties", "query", "type"]) ==
             "array"

    assert get_in(spec, ["input_schema", "properties", "action", "enum"]) ==
             ["index", "search", "open", "messages"]
  end

  test "view_analysis is exposed in tool specs" do
    spec = Enum.find(Tools.specs_for_api(), &(&1["name"] == "view_analysis"))

    refute is_nil(spec)
    assert get_in(spec, ["input_schema", "required"]) == ["ids"]
  end

  test "elixir_eval docs action returns a Froth module overview" do
    assert {:ok, [%Block{} = block]} =
             Tools.execute("elixir_eval", %{"action" => "docs"}, 0, [])

    assert Block.attr(block, :kind) == "module_overview"
    assert Block.attr(block, :app) == "froth"
    assert block.body =~ "Froth module hierarchy"
    assert block.body =~ "Telegram"
  end

  test "elixir_eval docs action returns function docs with source clips" do
    assert {:ok, [%Block{} = block]} =
             Tools.execute(
               "elixir_eval",
               %{
                 "action" => "docs",
                 "targets" => ["Froth.help/1"],
                 "include_source" => true
               },
               0,
               []
             )

    assert Block.attr(block, :kind) == "function"
    assert Block.attr(block, :function) == "help/1"
    assert block.body =~ "Pretty-print module docs"

    source_block =
      Enum.find(block.children, &(Block.attr(&1, :kind) == "source_code"))

    refute is_nil(source_block)
    assert source_block.body =~ "def help(module)"
    assert source_block.body =~ "Code.fetch_docs"
  end

  test "podcast docs expose the complete voice-cloning workflow" do
    assert {:ok, [%Block{} = block]} =
             Tools.execute(
               "elixir_eval",
               %{
                 "action" => "docs",
                 "targets" => ["Froth.Podcast"]
               },
               0,
               []
             )

    assert Block.attr(block, :kind) == "module"
    assert block.body =~ "Cloning a voice from YouTube"
    assert block.body =~ "Froth.Podcast.analyze_voices_youtube"
    assert block.body =~ "Froth.Podcast.download_youtube"
    assert block.body =~ "Froth.Podcast.clone_voice"
    assert block.body =~ "Froth.Podcast.generate"
  end

  test "view_analysis returns one block per matching analysis id" do
    first =
      Repo.insert!(
        Analysis.changeset(%Analysis{}, %{
          type: "image",
          chat_id: unique_chat_id(),
          message_id: 101,
          agent: "vision",
          analysis_text: "first analysis text",
          generated_at: DateTime.utc_now()
        })
      )

    second =
      Repo.insert!(
        Analysis.changeset(%Analysis{}, %{
          type: "pdf",
          chat_id: unique_chat_id(),
          message_id: 202,
          agent: "charlie",
          analysis_text: "second analysis text",
          generated_at: DateTime.utc_now()
        })
      )

    assert {:ok, [%Block{} = block_a, %Block{} = block_b]} =
             Tools.execute(
               "view_analysis",
               %{"ids" => [second.id, first.id]},
               0,
               []
             )

    blocks_by_id = Map.new([block_a, block_b], &{Block.attr(&1, :id), &1})

    assert Block.attr(blocks_by_id[first.id], :kind) == "analysis"
    assert Block.attr(blocks_by_id[first.id], :type) == "image"
    assert Block.attr(blocks_by_id[first.id], :message_id) == 101
    assert Block.attr(blocks_by_id[first.id], :agent) == "vision"
    assert blocks_by_id[first.id].body == "first analysis text"

    assert Block.attr(blocks_by_id[second.id], :kind) == "analysis"
    assert Block.attr(blocks_by_id[second.id], :type) == "pdf"
    assert Block.attr(blocks_by_id[second.id], :message_id) == 202
    assert Block.attr(blocks_by_id[second.id], :agent) == "charlie"
    assert blocks_by_id[second.id].body == "second analysis text"
  end

  test "timeline browse mode renders messages and attached analyses through bot context" do
    chat_id = unique_chat_id()
    session_id = "timeline-browse-#{System.unique_integer([:positive])}"

    insert_telegram_message(
      session_id,
      chat_id,
      101,
      7,
      1_700_000_100,
      "older context"
    )

    insert_telegram_message(
      session_id,
      chat_id,
      102,
      8,
      1_700_000_200,
      "photo caption"
    )

    analysis =
      Repo.insert!(
        Analysis.changeset(%Analysis{}, %{
          type: "image",
          chat_id: chat_id,
          message_id: 102,
          agent: "vision",
          analysis_text: "the image shows a red notebook on a table",
          generated_at: DateTime.utc_now()
        })
      )

    assert {:ok, timeline} =
             Tools.execute(
               "timeline",
               %{"limit" => 10},
               chat_id,
               bot_id: "charlie",
               session_id: session_id
             )

    assert timeline =~ ~s(<text id=tg:101)
    assert timeline =~ "older context"
    assert timeline =~ ~s(<text id=tg:102)
    assert timeline =~ "photo caption"
    assert timeline =~ ~s(<analysis id=#{analysis.id})
    assert timeline =~ "the image shows a red notebook on a table"
    assert timeline =~ "<info>"
  end

  test "timeline search mode includes surrounding context in chronological order" do
    chat_id = unique_chat_id()
    session_id = "timeline-search-#{System.unique_integer([:positive])}"

    insert_telegram_message(
      session_id,
      chat_id,
      201,
      7,
      1_700_001_100,
      "before context"
    )

    insert_telegram_message(
      session_id,
      chat_id,
      202,
      8,
      1_700_001_200,
      "needle phrase here"
    )

    insert_telegram_message(
      session_id,
      chat_id,
      203,
      9,
      1_700_001_300,
      "after context"
    )

    assert {:ok, timeline} =
             Tools.execute(
               "timeline",
               %{
                 "scope" => "messages",
                 "query" => ["needle phrase"],
                 "before" => 1,
                 "after" => 1,
                 "limit" => 5
               },
               chat_id,
               bot_id: "charlie",
               session_id: session_id
             )

    before_pos = :binary.match(timeline, "before context") |> elem(0)
    hit_pos = :binary.match(timeline, "needle phrase here") |> elem(0)
    after_pos = :binary.match(timeline, "after context") |> elem(0)

    assert before_pos < hit_pos
    assert hit_pos < after_pos
    assert timeline =~ ~s(<text id=tg:201)
    assert timeline =~ ~s(<text id=tg:202)
    assert timeline =~ ~s(<text id=tg:203)
  end

  test "timeline index exposes stable refs at each active narrative resolution" do
    chat_id = unique_chat_id()

    first_week =
      insert_summary(
        chat_id,
        ~D[2026-04-06],
        ~D[2026-04-13],
        "First week",
        "weekly_chronicle"
      )

    volume =
      insert_summary(
        chat_id,
        ~D[2026-04-06],
        ~D[2026-04-13],
        "# Volume: First Arc\n\nClosed arc.",
        "chronicle_volume",
        %{"source_summary_ids" => [first_week.id]}
      )

    recent_week =
      insert_summary(
        chat_id,
        ~D[2026-04-13],
        ~D[2026-04-20],
        "# Chapter: Recent Week\n\nStill detailed.",
        "weekly_chronicle"
      )

    long_daily_opening = String.duplicate("Uncovered daily narrative ", 20)

    day =
      insert_summary(
        chat_id,
        ~D[2026-04-20],
        ~D[2026-04-21],
        long_daily_opening
      )

    assert {:ok, index} = Tools.execute("timeline", %{}, chat_id, [])

    assert index =~ "<timeline-index>"
    assert index =~ "foundation:ch01-the-founding"
    assert index =~ "volume:#{volume.id}"
    assert index =~ "week:#{recent_week.id}"
    assert index =~ "day:#{day.id}"
    assert index =~ "volume → week → day"

    [_, daily_title] =
      Regex.run(~r/<interval ref="day:#{day.id}"[^>]+title="([^"]+)"/, index)

    assert String.length(daily_title) <= 161
  end

  test "timeline open descends from a volume to its source weeks" do
    chat_id = unique_chat_id()

    day =
      insert_summary(
        chat_id,
        ~D[2026-05-04],
        ~D[2026-05-05],
        "The exact day."
      )

    week =
      insert_summary(
        chat_id,
        ~D[2026-05-04],
        ~D[2026-05-11],
        "# Chapter 14: The Week\n\nWeekly detail.",
        "weekly_chronicle",
        %{"source_summary_ids" => [day.id]}
      )

    volume =
      insert_summary(
        chat_id,
        ~D[2026-05-04],
        ~D[2026-05-11],
        "# Volume IV: The Volume\n\nBroad arc.",
        "chronicle_volume",
        %{"source_summary_ids" => [week.id]}
      )

    assert {:ok, outline} =
             Tools.execute(
               "timeline",
               %{"ref" => "volume:#{volume.id}"},
               chat_id,
               []
             )

    assert outline =~ ~s(ref="volume:#{volume.id}")
    assert outline =~ ~s(ref="week:#{week.id}")
    assert outline =~ "Open a child week ref"

    assert {:ok, full} =
             Tools.execute(
               "timeline",
               %{
                 "action" => "open",
                 "ref" => "volume:#{volume.id}",
                 "detail" => "full"
               },
               chat_id,
               []
             )

    assert full =~ "Broad arc."

    assert {:ok, week_outline} =
             Tools.execute(
               "timeline",
               %{"action" => "open", "ref" => "week:#{week.id}"},
               chat_id,
               []
             )

    assert week_outline =~ ~s(ref="day:#{day.id}")
    assert week_outline =~ "call messages with this week ref"
  end

  test "timeline narrative search returns intervals rather than raw-message guesses" do
    chat_id = unique_chat_id()

    week =
      insert_summary(
        chat_id,
        ~D[2026-06-01],
        ~D[2026-06-08],
        "# Chapter: The Marmosets\n\nAstonishment depends on the hand.",
        "weekly_chronicle"
      )

    assert {:ok, result} =
             Tools.execute(
               "timeline",
               %{"action" => "search", "query" => ["marmosets"]},
               chat_id,
               []
             )

    assert result =~ ~s(<timeline-search scope="narrative")
    assert result =~ ~s(ref="week:#{week.id}")
    assert result =~ "Astonishment depends on the hand"
    refute result =~ "<text id=tg:"
  end

  test "timeline messages accepts a day ref and paginates primary evidence" do
    chat_id = unique_chat_id()
    session_id = "timeline-ref-#{System.unique_integer([:positive])}"

    day =
      insert_summary(
        chat_id,
        ~D[2026-07-01],
        ~D[2026-07-02],
        "A summarized day"
      )

    start = day_start(~D[2026-07-01])

    insert_telegram_message(session_id, chat_id, 301, 7, start + 10, "first")
    insert_telegram_message(session_id, chat_id, 302, 8, start + 20, "second")
    insert_telegram_message(session_id, chat_id, 303, 9, start + 30, "third")

    insert_telegram_message(
      session_id,
      chat_id,
      304,
      9,
      day_start(~D[2026-07-02]) + 10,
      "outside"
    )

    assert {:ok, first_page} =
             Tools.execute(
               "timeline",
               %{
                 "action" => "messages",
                 "ref" => "day:#{day.id}",
                 "limit" => 2
               },
               chat_id,
               session_id: session_id
             )

    assert first_page =~ "first"
    assert first_page =~ "second"
    refute first_page =~ "third"
    refute first_page =~ "outside"
    assert first_page =~ ~s(<next offset="2">)

    assert {:ok, second_page} =
             Tools.execute(
               "timeline",
               %{
                 "action" => "messages",
                 "ref" => "day:#{day.id}",
                 "limit" => 2,
                 "offset" => 2
               },
               chat_id,
               session_id: session_id
             )

    assert second_page =~ "third"
    refute second_page =~ "first"
    assert second_page =~ ~s(state="end-of-interval")
  end

  test "ask is exposed in tool specs" do
    spec = Enum.find(Tools.specs_for_api(), &(&1["name"] == "ask"))

    refute is_nil(spec)
    assert get_in(spec, ["input_schema", "required"]) == ["question"]
  end

  test "canonical tool descriptions include guidance previously duplicated in Charlie prompt" do
    specs = Map.new(Tools.specs_for_api(), &{&1["name"], &1})

    assert specs["send_message"]["description"] =~
             "one paragraph or one finished thought at a time"

    assert specs["ask"]["description"] =~ "pause the current agent cycle"
    refute Map.has_key?(specs, "read_log")
    refute Map.has_key?(specs, "search")
    refute Map.has_key?(specs, "read_tool_transcript")
    assert specs["timeline"]["description"] =~ "progressively finer"
    assert specs["timeline"]["description"] =~ "volume → week → day"
    assert specs["fetch"]["description"] =~ "saved as a local durable file"
    assert get_in(specs, ["elixir_eval", "input_schema", "required"]) == []

    assert specs["elixir_eval"]["description"] =~
             "discover, inspect, act loop"

    assert specs["elixir_eval"]["description"] =~
             ~s(call `action="docs"` with no targets)

    assert specs["elixir_eval"]["description"] =~
             "`Froth.help(Module)` is also available"

    assert specs["elixir_eval"]["description"] =~
             "use this tool for the running BEAM system"

    assert get_in(specs, [
             "elixir_eval",
             "input_schema",
             "properties",
             "action",
             "type"
           ]) ==
             "string"

    assert get_in(specs, [
             "elixir_eval",
             "input_schema",
             "properties",
             "targets",
             "type"
           ]) ==
             "array"

    assert get_in(specs, [
             "elixir_eval",
             "input_schema",
             "properties",
             "targets",
             "description"
           ]) =~ "Froth.Podcast"

    assert get_in(specs, [
             "elixir_eval",
             "input_schema",
             "properties",
             "include_source",
             "type"
           ]) ==
             "boolean"

    assert get_in(specs, ["run_shell", "input_schema", "required"]) == [
             "command",
             "description"
           ]

    assert get_in(specs, [
             "run_shell",
             "input_schema",
             "properties",
             "description",
             "required"
           ]) ==
             [
               "action",
               "goals",
               "assumptions"
             ]
  end

  test "elixir_eval eval action validates code and description at runtime" do
    assert {:error, "code must be a non-empty string"} =
             Tools.execute("elixir_eval", %{"action" => "eval"}, 0, [])

    assert {:error, "description must be an object for eval"} =
             Tools.execute(
               "elixir_eval",
               %{"action" => "eval", "code" => "1 + 1"},
               0,
               []
             )
  end

  test "spawn_agent is exposed in tool specs" do
    spec = Enum.find(Tools.specs_for_api(), &(&1["name"] == "spawn_agent"))

    refute is_nil(spec)
    assert get_in(spec, ["input_schema", "required"]) == ["prompt"]
  end

  test "spawn_agent starts an adhoc cycle with default tools, links it to the chat, and tracks it as a task" do
    %{bot_id: bot_id, session_id: session_id} = start_charlie_bot()
    chat_id = unique_chat_id()
    model = FakeLLM.claim()

    assert {:ok, result} =
             Tools.execute(
               "spawn_agent",
               %{
                 "prompt" => "Say hi from the delegated agent",
                 "model" => model
               },
               chat_id,
               bot_id: bot_id,
               bot_username: "charliebuddybot",
               session_id: session_id
             )

    assert result["status"] == "started"
    assert result["task_id"] == "agent:#{result["cycle_id"]}"
    assert result["model"] == model
    assert result["tools"] == ["run_shell", "elixir_eval"]
    assert result["open_url"] =~ result["cycle_id"]
    assert result["check_hint"] =~ result["task_id"]
    refute Map.has_key?(result, "check_tool")
    refute Map.has_key?(result, "check_input")

    assert_receive {FakeLLM, from, %Request{} = request}, 5_000

    assert [
             %LLMMessage{
               role: :user,
               content: [%{"type" => "text", "text" => prompt}]
             }
           ] =
             request.messages

    assert prompt == "Say hi from the delegated agent"
    assert request.model == model

    FakeLLM.reply(
      from,
      {:ok,
       %{
         text: "delegated answer",
         content: [%{"type" => "text", "text" => "delegated answer"}],
         stop_reason: "stop"
       }}
    )

    assert :ok = wait_for_cycle_status(result["cycle_id"], :completed)

    cycle = Repo.get!(Cycle, result["cycle_id"])
    assert cycle.status == :completed
    assert cycle.model == model

    assert Enum.map(cycle.config["tool_specs"], & &1["name"]) == [
             "run_shell",
             "elixir_eval"
           ]

    assert :ok = wait_for_task_status(result["task_id"], "completed")

    task = Repo.get!(Task, result["task_id"])
    assert task.type == "agent"
    assert task.status == "completed"
    assert task.metadata["cycle_id"] == result["cycle_id"]
    assert task.metadata["final_reply"] == "delegated answer"

    assert Repo.get_by!(CycleLink,
             cycle_id: result["cycle_id"],
             bot_id: bot_id,
             chat_id: chat_id
           )
  end

  test "spawn_agent runtime stops when the owning bot stops" do
    %{bot_runtime: _bot_runtime, bot_id: bot_id, session_id: session_id} =
      start_charlie_bot()

    chat_id = unique_chat_id()
    model = FakeLLM.claim()

    assert {:ok, result} =
             Tools.execute(
               "spawn_agent",
               %{
                 "prompt" => "Keep working until the bot goes away",
                 "model" => model
               },
               chat_id,
               bot_id: bot_id,
               bot_username: "charliebuddybot",
               session_id: session_id
             )

    assert_receive {FakeLLM, _from, %Request{}}, 5_000

    runtime_pid = wait_for_runtime(result["cycle_id"])
    ref = Process.monitor(runtime_pid)

    :ok = stop_supervised({Froth.Telegram.BotRuntime, bot_id})

    assert_receive {:DOWN, ^ref, :process, ^runtime_pid, _reason}, 5_000

    _ =
      :sys.get_state(
        Module.concat(Froth.Agent.CycleRegistry, "PIDPartition0")
      )

    refute is_pid(CycleRuntime.whereis(result["cycle_id"]))
  end

  test "ask sends an inline-keyboard question and persists a pending ask" do
    test_pid = self()
    chat_id = unique_chat_id()
    cycle_id = Repo.insert!(%Cycle{}).id

    send_message_fun = fn session_id, sent_chat_id, text, opts ->
      send(test_pid, {:ask_sent, session_id, sent_chat_id, text, opts})
      {:ok, %{"id" => 4321}}
    end

    assert {:await, payload} =
             Tools.execute(
               "ask",
               %{
                 "question" => "Pick one",
                 "alternatives" => ["Option A", "Option B"]
               },
               chat_id,
               session_id: "charlie",
               bot_id: "charlie",
               cycle_id: cycle_id,
               tool_use_id: "toolu_ask_1",
               system_prompt: "Test system prompt",
               model: "claude-opus-4-6",
               tools: Tools.specs_for_api(),
               thinking: %{"budget_tokens" => 128},
               effort: "high",
               reply_to: 555,
               send_message_fun: send_message_fun
             )

    assert payload["kind"] == "ask"
    assert payload["reason"] == "Waiting for the user's answer."
    assert payload["question_message_id"] == 4321

    assert_receive {:ask_sent, "charlie", ^chat_id, "Pick one", opts}, 1_000
    assert opts[:reply_to] == 555

    assert get_in(opts[:reply_markup], ["@type"]) ==
             "replyMarkupInlineKeyboard"

    assert get_in(opts[:reply_markup], [
             "rows",
             Access.at(0),
             Access.at(0),
             "text"
           ]) == "Option A"

    assert get_in(opts[:reply_markup], [
             "rows",
             Access.at(1),
             Access.at(0),
             "text"
           ]) == "Option B"

    pending_ask = Repo.get!(PendingAsk, payload["pending_ask_id"])
    assert pending_ask.chat_id == chat_id
    assert pending_ask.message_id == 4321
    assert pending_ask.tool_use_id == "toolu_ask_1"
    assert pending_ask.question == "Pick one"
    assert pending_ask.alternatives == ["Option A", "Option B"]
    assert pending_ask.config["system"] == "Test system prompt"
    assert pending_ask.config["model"] == "claude-opus-4-6"
    assert pending_ask.config["effort"] == "high"
  end

  test "spawn_agent rejects unknown tool names" do
    assert {:error, message} =
             Tools.execute(
               "spawn_agent",
               %{
                 "prompt" => "Delegate this",
                 "tools" => ["shell", "definitely_not_real"]
               },
               unique_chat_id(),
               bot_id: "charlie",
               bot_username: "charliebuddybot",
               session_id: "charlie"
             )

    assert message =~ "unknown tool names: definitely_not_real"
    assert message =~ "run_shell"
  end

  test "fetch validates message references before trying telegram download" do
    chat_id = unique_chat_id()

    assert {:error, message} =
             Tools.execute(
               "fetch",
               %{"source" => "msg:not_a_number"},
               chat_id,
               bot_id: "charlie",
               session_id: "charlie"
             )

    assert message =~ "Invalid source"
  end

  test "fetch loads a photo through telegram, materializes it, and inlines it by default" do
    chat_id = unique_chat_id()
    file_id = 987_651
    message_id = 12_341
    previous_base_url = Application.get_env(:froth, :files_base_url)

    Application.put_env(:froth, :files_base_url, "https://files.test/files")

    on_exit(fn ->
      if is_nil(previous_base_url) do
        Application.delete_env(:froth, :files_base_url)
      else
        Application.put_env(:froth, :files_base_url, previous_base_url)
      end
    end)

    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "froth-fetch-#{System.unique_integer([:positive])}.jpg"
      )

    image_data =
      <<0xFF, 0xD8, 0xFF>> <>
        Integer.to_string(System.unique_integer([:positive]))

    File.write!(tmp_path, image_data)
    on_exit(fn -> File.rm(tmp_path) end)

    session_id =
      start_fake_session(
        request_handler: fn
          %{
            "@type" => "getMessage",
            "chat_id" => ^chat_id,
            "message_id" => ^message_id
          } ->
            {:ok,
             %{
               "content" => %{
                 "@type" => "messagePhoto",
                 "photo" => %{
                   "sizes" => [
                     %{
                       "width" => 64,
                       "height" => 64,
                       "photo" => %{"id" => file_id}
                     }
                   ]
                 }
               }
             }}

          %{"@type" => "downloadFile", "file_id" => ^file_id} ->
            {:ok, %{"local" => %{"path" => tmp_path}}}

          _ ->
            :default
        end
      )

    assert {:ok, [%Block{} = block]} =
             Tools.execute(
               "fetch",
               %{"source" => "msg:#{message_id}"},
               chat_id,
               bot_id: "charlie",
               session_id: session_id
             )

    on_exit(fn -> File.rm(Block.attr(block, :local_path)) end)

    assert Block.attr(block, :kind) == "fetched"
    assert Block.attr(block, :source) == "msg:#{message_id}"
    # Synthesized filename uses photo basename + content-hash suffix
    assert Block.attr(block, :filename) =~ ~r/^photo-[0-9a-f]{8}\.jpg$/
    assert Block.attr(block, :mime) == "image/jpeg"
    assert Block.attr(block, :size) == byte_size(image_data)
    assert Block.attr(block, :public_url) =~ "https://files.test/files/"
    assert Block.attr(block, :local_path) =~ "/priv/static/files/"
    assert File.read!(Block.attr(block, :local_path)) == image_data
    # view defaults to true for images, so the body holds the bytes
    assert block.body == image_data
  end

  test "fetch loads a pdf document and skips inline view by default" do
    chat_id = unique_chat_id()
    file_id = 987_654
    message_id = 12_345
    previous_base_url = Application.get_env(:froth, :files_base_url)

    Application.put_env(:froth, :files_base_url, "https://files.test/files")

    on_exit(fn ->
      if is_nil(previous_base_url) do
        Application.delete_env(:froth, :files_base_url)
      else
        Application.put_env(:froth, :files_base_url, previous_base_url)
      end
    end)

    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "froth-fetch-#{System.unique_integer([:positive])}.pdf"
      )

    pdf_data = "%PDF-1.4\nfetch test\n"
    File.write!(tmp_path, pdf_data)
    on_exit(fn -> File.rm(tmp_path) end)

    session_id =
      start_fake_session(
        request_handler: fn
          %{
            "@type" => "getMessage",
            "chat_id" => ^chat_id,
            "message_id" => ^message_id
          } ->
            {:ok,
             %{
               "content" => %{
                 "@type" => "messageDocument",
                 "caption" => %{"text" => "Sample caption"},
                 "document" => %{
                   "document" => %{"id" => file_id},
                   "file_name" => "sample.pdf",
                   "mime_type" => "application/pdf"
                 }
               }
             }}

          %{"@type" => "downloadFile", "file_id" => ^file_id} ->
            {:ok, %{"local" => %{"path" => tmp_path}}}

          _ ->
            :default
        end
      )

    assert {:ok, [%Block{} = block]} =
             Tools.execute(
               "fetch",
               %{"source" => "tg:#{message_id}"},
               chat_id,
               bot_id: "charlie",
               session_id: session_id
             )

    on_exit(fn -> File.rm(Block.attr(block, :local_path)) end)

    assert Block.attr(block, :filename) == "sample.pdf"
    assert Block.attr(block, :mime) == "application/pdf"
    assert Block.attr(block, :size) == byte_size(pdf_data)
    assert Block.attr(block, :public_url) =~ "https://files.test/files/"
    assert Block.attr(block, :local_path) =~ "/priv/static/files/"
    assert File.read!(Block.attr(block, :local_path)) == pdf_data
    # PDFs default to view: false — durable file is materialized but
    # the body is nil so the agent has to opt in to inline the bytes.
    assert is_nil(block.body)
  end

  test "fetch loads a video and materializes it without inline view by default" do
    chat_id = unique_chat_id()
    file_id = 987_655
    message_id = 12_346
    previous_base_url = Application.get_env(:froth, :files_base_url)

    Application.put_env(:froth, :files_base_url, "https://files.test/files")

    on_exit(fn ->
      if is_nil(previous_base_url) do
        Application.delete_env(:froth, :files_base_url)
      else
        Application.put_env(:froth, :files_base_url, previous_base_url)
      end
    end)

    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "froth-fetch-#{System.unique_integer([:positive])}.mp4"
      )

    video_data =
      <<0, 0, 0, 24, ?f, ?t, ?y, ?p>> <>
        Integer.to_string(System.unique_integer([:positive]))

    File.write!(tmp_path, video_data)
    on_exit(fn -> File.rm(tmp_path) end)

    session_id =
      start_fake_session(
        request_handler: fn
          %{
            "@type" => "getMessage",
            "chat_id" => ^chat_id,
            "message_id" => ^message_id
          } ->
            {:ok,
             %{
               "content" => %{
                 "@type" => "messageVideo",
                 "video" => %{
                   "video" => %{"id" => file_id},
                   "file_name" => "clip.mp4",
                   "mime_type" => "video/mp4"
                 }
               }
             }}

          %{"@type" => "downloadFile", "file_id" => ^file_id} ->
            {:ok, %{"local" => %{"path" => tmp_path}}}

          _ ->
            :default
        end
      )

    assert {:ok, [%Block{} = block]} =
             Tools.execute(
               "fetch",
               %{"source" => message_id},
               chat_id,
               bot_id: "charlie",
               session_id: session_id
             )

    on_exit(fn -> File.rm(Block.attr(block, :local_path)) end)

    assert Block.attr(block, :filename) == "clip.mp4"
    assert Block.attr(block, :mime) == "video/mp4"
    assert Block.attr(block, :size) == byte_size(video_data)
    assert Block.attr(block, :public_url) =~ "https://files.test/files/"
    assert Block.attr(block, :local_path) =~ "/priv/static/files/"
    assert File.read!(Block.attr(block, :local_path)) == video_data
    assert is_nil(block.body)
  end

  test "fetch inlines a pdf when view is explicitly true" do
    chat_id = unique_chat_id()
    file_id = 987_656
    message_id = 12_347
    previous_base_url = Application.get_env(:froth, :files_base_url)

    Application.put_env(:froth, :files_base_url, "https://files.test/files")

    on_exit(fn ->
      if is_nil(previous_base_url) do
        Application.delete_env(:froth, :files_base_url)
      else
        Application.put_env(:froth, :files_base_url, previous_base_url)
      end
    end)

    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "froth-fetch-#{System.unique_integer([:positive])}.pdf"
      )

    pdf_data = "%PDF-1.4\nfetch view test\n"
    File.write!(tmp_path, pdf_data)
    on_exit(fn -> File.rm(tmp_path) end)

    session_id =
      start_fake_session(
        request_handler: fn
          %{
            "@type" => "getMessage",
            "chat_id" => ^chat_id,
            "message_id" => ^message_id
          } ->
            {:ok,
             %{
               "content" => %{
                 "@type" => "messageDocument",
                 "document" => %{
                   "document" => %{"id" => file_id},
                   "file_name" => "viewable.pdf",
                   "mime_type" => "application/pdf"
                 }
               }
             }}

          %{"@type" => "downloadFile", "file_id" => ^file_id} ->
            {:ok, %{"local" => %{"path" => tmp_path}}}

          _ ->
            :default
        end
      )

    assert {:ok, [%Block{} = block]} =
             Tools.execute(
               "fetch",
               %{"source" => message_id, "view" => true},
               chat_id,
               bot_id: "charlie",
               session_id: session_id
             )

    on_exit(fn -> File.rm(Block.attr(block, :local_path)) end)

    assert Block.attr(block, :filename) == "viewable.pdf"
    assert Block.attr(block, :mime) == "application/pdf"
    assert block.body == pdf_data
  end

  test "run_shell falls back to the current working directory for an empty working_dir" do
    {:ok, [%Froth.Context.Block{} = block]} =
      Tools.execute(
        "run_shell",
        %{"command" => "pwd", "working_dir" => ""},
        unique_chat_id(),
        []
      )

    task_id = Keyword.fetch!(block.attrs, :task_id)
    assert String.starts_with?(task_id, "shell:")

    working_dir =
      cond do
        is_binary(block.body) -> block.body
        true -> Enum.join(Keyword.get(block.attrs, :head, []), "\n")
      end
      |> String.trim()

    task = Repo.get!(Task, task_id)

    expected_stat = File.stat!(task.metadata["working_dir"])
    actual_stat = File.stat!(working_dir)

    assert {expected_stat.major_device, expected_stat.minor_device,
            expected_stat.inode} ==
             {actual_stat.major_device, actual_stat.minor_device,
              actual_stat.inode}

    assert working_dir != ""
  end

  defp insert_summary(
         chat_id,
         from_date,
         to_date,
         text,
         kind \\ nil,
         metadata \\ %{}
       ) do
    metadata = if kind, do: Map.put(metadata, "kind", kind), else: metadata

    %ChatSummary{}
    |> ChatSummary.changeset(%{
      chat_id: chat_id,
      from_date: day_start(from_date),
      to_date: day_start(to_date),
      agent: "claude-opus-4-6",
      summary_text: text,
      message_count: 10,
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp day_start(date),
    do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()

  defp unique_chat_id do
    9_000_000_000 + System.unique_integer([:positive])
  end

  defp insert_telegram_message(
         session_id,
         chat_id,
         message_id,
         sender_id,
         date,
         text
       ) do
    ensure_session(session_id)
    ensure_username(sender_id, session_id)

    raw = %{
      "id" => message_id,
      "chat_id" => chat_id,
      "sender_id" => %{"user_id" => sender_id},
      "date" => date,
      "content" => %{
        "@type" => "messageText",
        "text" => %{"text" => text}
      }
    }

    %TelegramMessage{}
    |> TelegramMessage.changeset(%{
      telegram_session_id: session_id,
      chat_id: chat_id,
      message_id: message_id,
      sender_id: sender_id,
      date: date,
      raw: raw
    })
    |> Repo.insert!()
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

  defp ensure_username(sender_id, session_id)
       when is_integer(sender_id) and sender_id > 0 do
    %Username{}
    |> Username.changeset(%{
      user_id: sender_id,
      label: "@user#{sender_id}",
      source_session_id: session_id
    })
    |> Repo.insert(
      on_conflict: [
        set: [
          label: "@user#{sender_id}",
          source_session_id: session_id,
          updated_at: DateTime.utc_now()
        ]
      ],
      conflict_target: :user_id
    )
  end

  defp ensure_username(_sender_id, _session_id), do: :ok

  defp wait_for_cycle_status(cycle_id, status, attempts \\ 100)

  defp wait_for_cycle_status(cycle_id, status, attempts)
       when is_binary(cycle_id) and attempts > 0 do
    case Repo.get!(Cycle, cycle_id).status do
      ^status ->
        :ok

      _other ->
        receive do
        after
          10 -> wait_for_cycle_status(cycle_id, status, attempts - 1)
        end
    end
  end

  defp wait_for_cycle_status(cycle_id, status, 0) do
    flunk("cycle #{cycle_id} did not reach status #{inspect(status)} in time")
  end

  defp wait_for_runtime(cycle_id, attempts \\ 100)

  defp wait_for_runtime(cycle_id, attempts)
       when is_binary(cycle_id) and attempts > 0 do
    case CycleRuntime.whereis(cycle_id) do
      pid when is_pid(pid) ->
        pid

      nil ->
        receive do
        after
          10 -> wait_for_runtime(cycle_id, attempts - 1)
        end
    end
  end

  defp wait_for_runtime(cycle_id, 0) do
    flunk("cycle runtime #{cycle_id} did not start in time")
  end

  defp wait_for_task_status(task_id, status, attempts \\ 100)

  defp wait_for_task_status(task_id, status, attempts)
       when is_binary(task_id) and is_binary(status) and attempts > 0 do
    case Repo.get!(Task, task_id).status do
      ^status ->
        :ok

      _other ->
        receive do
        after
          10 -> wait_for_task_status(task_id, status, attempts - 1)
        end
    end
  end

  defp wait_for_task_status(task_id, status, 0) do
    flunk("task #{task_id} did not reach status #{inspect(status)} in time")
  end
end
