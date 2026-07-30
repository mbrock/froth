defmodule Froth.ChronicleRollup do
  @moduledoc """
  Compacts closed runs of weekly Chronicle chapters into immutable volumes.

  Weekly chapters remain stored and searchable. A volume only changes which
  resolution is loaded into Charlie's standing context: older covered weeks
  are represented by the volume, while the newest weeks remain verbatim.
  """

  import Ecto.Query

  alias Froth.Agent
  alias Froth.Agent.{Config, Message}
  alias Froth.{ChatSummary, Repo, WeeklySummarizer}

  @kind "chronicle_volume"
  @model "claude-opus-4-6"
  @max_tokens 32_768
  @default_keep_weeks 4
  @default_min_source_weeks 8

  @system_prompt """
  You are editing The Chronicle, the durable narrative memory of a long-running
  group conversation and the software agents living inside it.

  Turn the supplied consecutive weekly chapters into one closed narrative
  volume. This is temporal compression, not a generic summary. Preserve the
  load-bearing scenes, exact names, important quotations, technical artifacts,
  philosophical arguments, reversals, running jokes, unresolved threads, and
  changes in relationships. Resolve repetition by stating a recurring pattern
  once at the level it became meaningful. Preserve chronology where sequence
  carries causality, but allow related events to braid together when that makes
  the longer arc clearer.

  Write for the same participants, not for an outside audience. Do not explain
  the premise, flatten uncertainty, invent connective tissue, or turn the
  people into character summaries. Give the period narrative closure without
  pretending that unresolved stories ended.

  Begin with a Markdown H1 naming the volume and its exact date range. Aim for
  roughly 2,500 to 4,000 words. No bullets, preamble, or meta-commentary.
  """

  def kind, do: @kind

  def list(chat_id) when is_integer(chat_id) do
    Repo.all(
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id,
        where: fragment("?->>'kind' = ?", s.metadata, @kind),
        order_by: [asc: s.from_date]
      ),
      log: false
    )
  end

  def pending_source_weeklies(chat_id, opts \\ [])
      when is_integer(chat_id) and is_list(opts) do
    keep_weeks = positive_opt(opts, :keep_weeks, @default_keep_weeks)
    covered_until = latest_covered_until(chat_id)

    chat_id
    |> WeeklySummarizer.list()
    |> Enum.filter(&(&1.from_date >= covered_until))
    |> Enum.drop(-keep_weeks)
  end

  def maybe_rollup(chat_id, opts \\ [])
      when is_integer(chat_id) and is_list(opts) do
    min_source_weeks =
      positive_opt(opts, :min_source_weeks, @default_min_source_weeks)

    sources = pending_source_weeklies(chat_id, opts)

    if length(sources) >= min_source_weeks do
      create(chat_id, sources, opts)
    else
      {:ok, nil}
    end
  end

  defp create(chat_id, [first | _] = sources, opts) do
    last = List.last(sources)
    previous = list(chat_id) |> List.last()
    prompt = build_prompt(first, last, previous, sources)
    agent_run_fun = Keyword.get(opts, :agent_run_fun, &Agent.run/2)

    config = %Config{
      system: @system_prompt,
      model: @model,
      max_tokens: @max_tokens,
      tools: []
    }

    {cycle, stream} = agent_run_fun.(Message.user(prompt), config)

    text =
      Enum.reduce(stream, nil, fn
        {:stream, {:text_delta, delta}}, acc ->
          IO.write(delta)
          acc

        {:message, %{role: :agent} = message}, _acc ->
          Message.extract_text(message.content)

        _, acc ->
          acc
      end)

    IO.write("\n")

    if is_binary(text) and String.trim(text) != "" do
      save(chat_id, first, last, previous, sources, cycle.id, text)
    else
      {:error, :no_response}
    end
  end

  defp build_prompt(first, last, previous, sources) do
    source_text =
      Enum.map_join(sources, "\n\n", fn summary ->
        """
        --- #{date(summary.from_date)} to #{date(summary.to_date - 1)} ---
        #{summary.summary_text}
        """
      end)

    previous_context =
      case previous do
        nil ->
          manual_chronicle()

        summary ->
          """
          The immediately preceding closed volume, supplied only for continuity:

          #{summary.summary_text}
          """
      end

    """
    CONTINUITY BEFORE THIS VOLUME:

    #{previous_context}

    WEEKLY CHAPTERS TO REALIZE AS ONE CLOSED VOLUME:

    #{source_text}

    The new volume covers #{date(first.from_date)} through
    #{date(last.to_date - 1)}. Represent that interval exactly once.
    """
  end

  defp save(chat_id, first, last, previous, sources, cycle_id, text) do
    %ChatSummary{}
    |> ChatSummary.changeset(%{
      chat_id: chat_id,
      from_date: first.from_date,
      to_date: last.to_date,
      agent: @model,
      summary_text: text,
      message_count: Enum.sum(Enum.map(sources, &(&1.message_count || 0))),
      metadata: %{
        "kind" => @kind,
        "cycle_id" => cycle_id,
        "previous_volume_id" => previous && previous.id,
        "source_summary_ids" => Enum.map(sources, & &1.id)
      }
    })
    |> Repo.insert()
  end

  defp latest_covered_until(chat_id) do
    case list(chat_id) |> List.last() do
      nil -> 0
      summary -> summary.to_date
    end
  end

  defp manual_chronicle do
    :froth
    |> Application.app_dir("priv/chronicle/*.md")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map_join("\n\n", &File.read!/1)
  end

  defp positive_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp date(unix), do: unix |> DateTime.from_unix!() |> DateTime.to_date()
end
