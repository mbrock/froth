defmodule Froth.Headlines do
  @moduledoc """
  Extract significant daily headlines from stored chat summaries.

      # Froth.Headlines.extract()
      # Froth.Headlines.extract(chat_id: -1003690254489)
  """

  import Ecto.Query

  alias Froth.Agent
  alias Froth.Agent.Config
  alias Froth.Agent.CycleRuntime
  alias Froth.Agent.Message, as: AgentMessage
  alias Froth.ChatSummary
  alias Froth.Event
  alias Froth.Inference.Tools
  alias Froth.Repo
  alias Froth.Telegram.Charlie

  @default_chat_id -1_003_690_254_489
  @model "gpt-5.4"
  @system_prompt "You are a tabloid editor."

  @spec start(keyword()) :: {Froth.Agent.Cycle.t(), Enumerable.t()}
  def start(opts \\ []) when is_list(opts) do
    {cycle, runtime_opts} = prepare_cycle(opts)
    {cycle, CycleRuntime.event_stream_for(runtime_opts)}
  end

  @spec extract(keyword()) :: {Froth.Agent.Cycle.t(), term()}
  def extract(opts \\ []) when is_list(opts) do
    {_cycle, runtime_opts} = prepare_cycle(opts)
    CycleRuntime.run_to_completion(runtime_opts)
  end

  @spec extract_all(keyword()) :: {Froth.Agent.Cycle.t(), term()}
  def extract_all(opts \\ []), do: extract(opts)

  defp prepare_cycle(opts) when is_list(opts) do
    chat_id = Keyword.get(opts, :chat_id, @default_chat_id)
    model = Keyword.get(opts, :model, @model)
    spam = Keyword.get(opts, :spam, true)

    prompt = build_prompt_for_chat(chat_id)
    config = build_headlines_config(chat_id, model)

    user_message =
      Repo.insert!(%AgentMessage{role: :user, content: AgentMessage.wrap(prompt)})

    cycle = Agent.begin_cycle(user_message, config)

    charlie_defaults = Charlie.default_config()

    runtime_opts = [
      cycle_id: cycle.id,
      cycle: cycle,
      worker_config: config,
      bot_id: "charlie",
      chat_id: chat_id,
      spam: spam,
      # Headlines run outside a Bot — supply session/bot identity from
      # the Charlie profile so tool execution (narration, send_message,
      # etc.) has a real TDLib session + username to post to.
      bot_config: charlie_bot_config(charlie_defaults, model)
    ]

    {cycle, runtime_opts}
  end

  defp build_prompt_for_chat(chat_id) when is_integer(chat_id) do
    summaries = list_summaries(chat_id)
    registered_headlines = list_registered_headlines(chat_id)

    summaries
    |> render_summary_context()
    |> build_prompt(render_registered_headlines_context(registered_headlines))
  end

  defp build_headlines_config(chat_id, model) when is_integer(chat_id) and is_binary(model) do
    %Config{
      provider: :openai,
      system: @system_prompt,
      model: model,
      tools: headline_tools(),
      tool_executor: nil,
      context: %{chat_id: chat_id},
      parent_span_id: nil,
      thinking: nil,
      effort: "medium",
      reasoning_summary: "auto"
    }
  end

  defp charlie_bot_config(%{} = charlie_defaults, model) do
    # Best-effort `BotConfig` for the background Headlines runtime. We
    # don't own a live Bot process for this path — this snapshot is
    # consumed by the runtime's `execution_base` to build the tool
    # context (bot_id, bot_username, session_id, model, etc.).
    Froth.Telegram.Bot.Config.build(
      id: "charlie",
      session_id: charlie_defaults.session_id,
      bot_username: charlie_defaults.bot_username,
      bot_user_id: Map.get(charlie_defaults, :bot_user_id, 0),
      owner_user_id: Map.get(charlie_defaults, :owner_user_id, 0),
      model: model,
      system_prompt: @system_prompt,
      tools: headline_tools()
    )
  end

  defp list_summaries(chat_id) when is_integer(chat_id) do
    Repo.all(
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id,
        order_by: [asc: s.from_date],
        select: %{from_date: s.from_date, to_date: s.to_date, summary_text: s.summary_text}
      ),
      log: false
    )
  end

  defp render_summary_context(summaries) when is_list(summaries) do
    summaries
    |> Enum.map(fn summary ->
      "<summary date=\"#{summary_date(summary.from_date)}\">\n#{summary.summary_text}\n</summary>"
    end)
    |> Enum.join("\n\n")
  end

  defp build_prompt(summary_context, registered_headlines_context) do
    instruction = """
    <objective>
    Write tabloid headlines for EVERY summary date in the context.
    Existing registered headlines are included below in XML. Those days are already done.
    </objective>

    <headline_selection>
    #{headline_selection_rules()}
    A day can have multiple real headlines. If a day has several distinct developments, register all of them together.
    Do not stop at one headline for a day unless that day truly has only one substantial development worth remembering.
    Before you register a date, make sure you have the complete set of worthy headlines for that day, not just the first good one you found.
    Only include items that are genuinely worth headlining, but include ALL of them once they clear that bar.
    </headline_selection>

    <research_workflow>
    Use read_log and search to investigate details and find an approximate UTC time range for each headline before registering it.
    Prefer targeted searches and narrow log windows. Avoid repeatedly pulling large log spans once you already have enough evidence for that day.
    You do not need to finish all research before you start registering. As soon as one day is sufficiently researched and complete, call register_headlines for that day and then continue to the next unfinished day.
    After you register a date, stop researching that date unless you uncover a clear miss.
    </research_workflow>

    <registration_rules>
    Each headline must include from_time and to_time as ISO 8601 UTC datetime strings bracketing when the event happened.
    You may register headlines in any order.
    Call register_headlines once per date.
    When you register a day, include the full set of worthy headlines for that day in a single register_headlines call.
    In the register_headlines arguments, the headlines array is the complete deliverable for that date. Put EVERY headline worth keeping for that date into that array.
    Do not submit a representative sample. Do not leave obvious same-day headlines for a later pass.
    A headlines array of length 1 is only correct when that date truly has exactly one worthy headline after investigation.
    The tool response will tell you what's left, so keep going until every available summary date is done.
    </registration_rules>
    """

    [summary_context, registered_headlines_context, instruction]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp list_registered_headlines(chat_id) when is_integer(chat_id) do
    chat_id_string = Integer.to_string(chat_id)

    Repo.all(
      from(e in Event,
        where:
          e.event == "froth.headlines.registered" and
            fragment("?->>'chat_id' = ?", e.metadata, ^chat_id_string),
        order_by: [desc: e.inserted_at],
        select: %{inserted_at: e.inserted_at, metadata: e.metadata}
      ),
      log: false
    )
    |> Enum.reduce({MapSet.new(), []}, fn event, {seen_dates, acc} ->
      date = get_in(event, [:metadata, "date"])
      headlines = get_in(event, [:metadata, "headlines"])

      cond do
        not is_binary(date) or MapSet.member?(seen_dates, date) ->
          {seen_dates, acc}

        not is_list(headlines) ->
          {MapSet.put(seen_dates, date), acc}

        true ->
          {MapSet.put(seen_dates, date), [%{date: date, headlines: headlines} | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp render_registered_headlines_context([]), do: ""

  defp render_registered_headlines_context(registered_headlines)
       when is_list(registered_headlines) do
    body =
      registered_headlines
      |> Enum.map_join("\n\n", fn %{date: date, headlines: headlines} ->
        rendered_headlines =
          headlines
          |> Enum.map_join("\n", &render_registered_headline/1)

        ~s(<headlines date="#{xml_escape(date)}">\n#{rendered_headlines}\n</headlines>)
      end)

    "<existing_headlines>\n" <> body <> "\n</existing_headlines>"
  end

  defp render_registered_headline(%{
         "emoji" => emoji,
         "title" => title,
         "sentence" => sentence,
         "from_time" => from_time,
         "to_time" => to_time
       }) do
    [
      ~s(<headline from_time="#{xml_escape(from_time)}" to_time="#{xml_escape(to_time)}">),
      ~s(  <emoji>#{xml_escape(emoji)}</emoji>),
      ~s(  <title>#{xml_escape(title)}</title>),
      ~s(  <sentence>#{xml_escape(sentence)}</sentence>),
      "</headline>"
    ]
    |> Enum.join("\n")
  end

  defp render_registered_headline(_headline), do: "<headline />"

  defp headline_tools do
    Tools.specs_for_names(["read_log", "search"]) ++ [register_headlines_spec()]
  end

  defp register_headlines_spec do
    %{
      "name" => "register_headlines",
      "description" =>
        "Submit the complete final set of headlines for one date after investigating the evidence. The headlines array must contain every item worth headlining for that date, not just one example.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "date" => %{
            "type" => "string",
            "description" => "The date being summarized, YYYY-MM-DD"
          },
          "headlines" => %{
            "type" => "array",
            "description" =>
              "The complete set of headlines worth keeping for this date. Include every worthy same-day headline in this array.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "emoji" => %{
                  "type" => "string",
                  "description" => "A single relevant emoji for the headline"
                },
                "title" => %{"type" => "string", "description" => "Short headline title"},
                "sentence" => %{
                  "type" => "string",
                  "description" => "One sentence expanding on the headline"
                },
                "from_time" => %{
                  "type" => "string",
                  "description" => "Approximate event start time, ISO 8601 UTC datetime string"
                },
                "to_time" => %{
                  "type" => "string",
                  "description" => "Approximate event end time, ISO 8601 UTC datetime string"
                }
              },
              "required" => ["emoji", "title", "sentence", "from_time", "to_time"],
              "additionalProperties" => false
            }
          }
        },
        "required" => ["date", "headlines"],
        "additionalProperties" => false
      }
    }
  end

  defp summary_date(from_ts) when is_integer(from_ts) do
    from_ts
    |> div(86_400)
    |> Kernel.+(719_528)
    |> Date.from_gregorian_days()
    |> Date.to_iso8601()
  end

  defp headline_selection_rules do
    "Recurring automated events (scheduled scans, hourly podcasts, Tototo sleeping) are NOT headlines unless something broke or changed."
  end

  defp xml_escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
