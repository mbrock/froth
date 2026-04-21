defmodule Froth.Headlines do
  @moduledoc """
  Extract significant daily headlines from stored chat summaries.

  Headlines runs as a bot-owned agent cycle under an existing Bot —
  the Bot supplies both the TDLib/session identity that tool execution
  needs and the owning supervisor for the cycle runtime. Pass the
  running Bot via the `:bot` option:

      Froth.Headlines.extract(bot: Froth.Telegram.Bot.Charlie,
                              chat_id: -1003690254489)

  `:bot` accepts a pid, a registered name atom, or a `{:via, ...}`
  tuple — anything `Froth.Telegram.Bot.snapshot/1` can resolve.
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
  alias Froth.Telegram.Bot
  alias Froth.Tools.RegisterHeadlines, as: RegisterHeadlinesTool

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
    bot_ref = Keyword.fetch!(opts, :bot)
    {_bot_pid, bot_config} = Bot.snapshot(bot_ref)

    chat_id = Keyword.get(opts, :chat_id, @default_chat_id)
    model = Keyword.get(opts, :model, @model)
    provider = Keyword.get(opts, :provider, :openai)
    spam = Keyword.get(opts, :spam, true)

    prompt = build_prompt_for_chat(chat_id)
    config = build_headlines_config(chat_id, model, provider)

    user_message =
      Repo.insert!(%AgentMessage{
        role: :user,
        content: AgentMessage.wrap(prompt)
      })

    cycle = Agent.begin_cycle(user_message, config)

    runtime_opts = [
      cycle_id: cycle.id,
      cycle: cycle,
      worker_config: config,
      bot_id: bot_config.id,
      chat_id: chat_id,
      spam: spam,
      bot_ref: bot_ref
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

  defp build_headlines_config(chat_id, model, provider)
       when is_integer(chat_id) and is_binary(model) and is_atom(provider) do
    %Config{
      provider: provider,
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

  defp list_summaries(chat_id) when is_integer(chat_id) do
    Repo.all(
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id,
        order_by: [asc: s.from_date],
        select: %{
          from_date: s.from_date,
          to_date: s.to_date,
          summary_text: s.summary_text
        }
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
    Use timeline to investigate details and find an approximate UTC time range for each headline before registering it.
    Omit query to browse a date window. Add query plus before/after when you need targeted phrase search with surrounding context.
    Prefer focused queries and narrow date windows. Avoid repeatedly pulling large spans once you already have enough evidence for that day.
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
          {MapSet.put(seen_dates, date),
           [%{date: date, headlines: headlines} | acc]}
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
    Tools.specs_for_names(["timeline"]) ++ [RegisterHeadlinesTool.spec()]
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
