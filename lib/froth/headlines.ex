defmodule Froth.Headlines do
  @moduledoc """
  Extract significant daily headlines from stored chat summaries.

      # Froth.Headlines.extract(~D[2026-03-22])
      # Froth.Headlines.extract(~D[2026-03-22], chat_id: -1003690254489)
  """

  import Ecto.Query

  alias Froth.Agent.Adhoc
  alias Froth.ChatSummary
  alias Froth.Inference.Tools
  alias Froth.Repo
  alias Froth.Telegram.BotContext

  @default_chat_id -1_003_690_254_489
  @model "gpt-5.4"
  @system_prompt """
  You are a historian extracting the most significant events from a daily chat log.
  Use the register_headlines tool to submit your findings.
  You may use read_log and search to investigate details before registering.
  Be selective: only the events that matter.
  """

  @spec extract(Date.t(), keyword()) :: {Froth.Agent.Cycle.t(), term()}
  def extract(%Date{} = date, opts \\ []) when is_list(opts) do
    chat_id = Keyword.get(opts, :chat_id, @default_chat_id)

    prompt =
      chat_id
      |> list_summaries()
      |> render_summary_context()
      |> build_prompt(date)

    Adhoc.run(prompt,
      provider: :openai,
      model: @model,
      system: @system_prompt,
      chat_id: chat_id,
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
      %{
        date: summary_date(summary.from_date),
        text: summary.summary_text
      }
    end)
    |> BotContext.render_summaries()
    |> Enum.join("\n\n")
  end

  defp build_prompt(summary_context, %Date{} = date) do
    date_string = Date.to_iso8601(date)

    instruction = """
    Extract the most significant and memorable events from #{date_string}.
    You may use read_log and search to investigate details before deciding.
    When you are ready, call register_headlines exactly once with date=#{date_string}.
    """

    [summary_context, instruction]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp headline_tools do
    Tools.specs_for_names(["read_log", "search"]) ++ [register_headlines_spec()]
  end

  defp register_headlines_spec do
    %{
      "name" => "register_headlines",
      "description" =>
        "Submit the final set of headlines for the target date after you have investigated the evidence.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "date" => %{
            "type" => "string",
            "description" => "The date being summarized, YYYY-MM-DD"
          },
          "headlines" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "title" => %{"type" => "string", "description" => "Short headline title"},
                "sentence" => %{
                  "type" => "string",
                  "description" => "One sentence expanding on the headline"
                }
              },
              "required" => ["title", "sentence"],
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
end
