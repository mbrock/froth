defmodule Froth.AgentInspect do
  @moduledoc false

  import Ecto.Query

  alias Froth.{Event, ObjectStore, Repo}
  alias Froth.Telegram.CycleLink

  def recent_cycle_ids(bot_id, limit \\ 5)
      when is_binary(bot_id) and is_integer(limit) and limit > 0 do
    Repo.all(
      from(cl in CycleLink,
        where: cl.bot_id == ^bot_id,
        order_by: [desc: cl.inserted_at],
        limit: ^limit,
        select: cl.cycle_id
      ),
      log: false
    )
  end

  def cache_report(bot_id, limit \\ 5)
      when is_binary(bot_id) and is_integer(limit) and limit > 0 do
    cycle_ids = recent_cycle_ids(bot_id, limit)
    requested_by_cycle = requested_events_by_cycle(cycle_ids)
    completed_by_cycle = completed_events_by_cycle(cycle_ids)

    Enum.map(cycle_ids, fn cycle_id ->
      requested = Map.get(requested_by_cycle, cycle_id)
      payload = load_event_payload(requested)

      %{
        cycle_id: cycle_id,
        requested_at: requested && requested.inserted_at,
        request_summary: payload && request_summary_from_payload(payload),
        passes: Map.get(completed_by_cycle, cycle_id, [])
      }
    end)
  end

  def print_cache_report(bot_id, limit \\ 5)
      when is_binary(bot_id) and is_integer(limit) and limit > 0 do
    cache_report(bot_id, limit)
    |> Enum.each(fn row ->
      request_summary = row.request_summary || %{}

      IO.puts(
        "#{row.cycle_id} | #{format_datetime(row.requested_at)} | " <>
          "blocks=#{Map.get(request_summary, :content_length, 0)} | " <>
          "breakpoints=#{format_breakpoints(Map.get(request_summary, :breakpoints, []))}"
      )

      Enum.each(row.passes, fn pass ->
        IO.puts(
          "  seq=#{pass.seq} stop=#{pass.stop_reason} " <>
            "cw=#{pass.cache_creation_input_tokens} cr=#{pass.cache_read_input_tokens} " <>
            "in=#{pass.input_tokens} out=#{pass.output_tokens}"
        )
      end)
    end)

    :ok
  end

  def request_summary(cycle_id) when is_binary(cycle_id) do
    with %{metadata: _metadata} = event <- first_requested_event(cycle_id),
         payload when is_map(payload) <- load_event_payload(event) do
      Map.merge(
        %{
          cycle_id: cycle_id,
          requested_at: event.inserted_at,
          blob_ref: event.metadata["blob_ref"]
        },
        request_summary_from_payload(payload)
      )
    else
      _ -> nil
    end
  end

  def print_request_summary(cycle_id) when is_binary(cycle_id) do
    case request_summary(cycle_id) do
      nil ->
        IO.puts("no first llm.requested event found for #{cycle_id}")

      summary ->
        IO.puts("#{summary.cycle_id} | #{format_datetime(summary.requested_at)}")
        IO.puts("blob_ref=#{summary.blob_ref || "-"}")
        IO.puts("blocks=#{summary.content_length}")
        IO.puts("breakpoints=#{format_breakpoints(summary.breakpoints)}")
        IO.puts("tail:")

        Enum.each(summary.tail, fn row ->
          marker = if row.cache_control?, do: "cc", else: "--"
          IO.puts("  #{row.idx} #{marker} #{row.label}")
        end)
    end

    :ok
  end

  def request_summary_from_payload(payload, tail_count \\ 8)
      when is_map(payload) and is_integer(tail_count) and tail_count > 0 do
    content = first_user_content(payload)

    %{
      content_length: length(content),
      breakpoints: breakpoint_rows(content),
      tail: tail_rows(content, tail_count)
    }
  end

  defp first_requested_event(cycle_id) do
    Repo.one(
      from(e in Event,
        where:
          e.event == "froth.agent.llm.requested" and
            fragment("?->>'cycle_id' = ?", e.metadata, ^cycle_id),
        order_by: [asc: fragment("COALESCE((?->>'seq')::bigint, 0)", e.metadata)],
        limit: 1,
        select: %{inserted_at: e.inserted_at, metadata: e.metadata}
      ),
      log: false
    )
  end

  defp requested_events_by_cycle([]), do: %{}

  defp requested_events_by_cycle(cycle_ids) do
    Repo.all(
      from(e in Event,
        where:
          e.event == "froth.agent.llm.requested" and
            fragment("?->>'cycle_id' = ANY(?)", e.metadata, type(^cycle_ids, {:array, :string})),
        order_by: [
          asc: fragment("?->>'cycle_id'", e.metadata),
          asc: fragment("COALESCE((?->>'seq')::bigint, 0)", e.metadata)
        ],
        select: %{inserted_at: e.inserted_at, metadata: e.metadata}
      ),
      log: false
    )
    |> Enum.group_by(& &1.metadata["cycle_id"])
    |> Map.new(fn {cycle_id, events} -> {cycle_id, List.first(events)} end)
  end

  defp completed_events_by_cycle([]), do: %{}

  defp completed_events_by_cycle(cycle_ids) do
    Repo.all(
      from(e in Event,
        where:
          e.event == "froth.agent.llm.completed" and
            fragment("?->>'cycle_id' = ANY(?)", e.metadata, type(^cycle_ids, {:array, :string})),
        order_by: [
          asc: fragment("?->>'cycle_id'", e.metadata),
          asc: fragment("COALESCE((?->>'seq')::bigint, 0)", e.metadata)
        ],
        select: %{inserted_at: e.inserted_at, metadata: e.metadata}
      ),
      log: false
    )
    |> Enum.group_by(& &1.metadata["cycle_id"])
    |> Map.new(fn {cycle_id, events} ->
      passes =
        Enum.map(events, fn event ->
          usage = event.metadata["usage"] || %{}

          %{
            seq: event_seq(event.metadata),
            stop_reason: event.metadata["stop_reason"],
            cache_creation_input_tokens: usage["cache_creation_input_tokens"] || 0,
            cache_read_input_tokens: usage["cache_read_input_tokens"] || 0,
            input_tokens: usage["input_tokens"] || 0,
            output_tokens: usage["output_tokens"] || 0
          }
        end)

      {cycle_id, passes}
    end)
  end

  defp load_event_payload(nil), do: nil

  defp load_event_payload(%{metadata: %{"blob_ref" => blob_ref}})
       when is_binary(blob_ref) and blob_ref != "" do
    case ObjectStore.get(blob_ref) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, payload} when is_map(payload) -> payload
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp load_event_payload(%{metadata: metadata}) when is_map(metadata), do: metadata

  defp first_user_content(%{"messages" => messages}) when is_list(messages) do
    Enum.find_value(messages, [], fn
      %{"role" => "user", "content" => content} when is_list(content) -> content
      _ -> nil
    end) || []
  end

  defp first_user_content(_payload), do: []

  defp breakpoint_rows(content) when is_list(content) do
    content
    |> Enum.with_index()
    |> Enum.flat_map(fn {block, idx} ->
      if is_map(block) and is_map(block["cache_control"]) do
        [%{idx: idx, label: block_label(block)}]
      else
        []
      end
    end)
  end

  defp tail_rows(content, tail_count) when is_list(content) do
    start_idx = max(length(content) - tail_count, 0)

    content
    |> Enum.drop(start_idx)
    |> Enum.with_index(start_idx)
    |> Enum.map(fn {block, idx} ->
      %{
        idx: idx,
        cache_control?: is_map(block) and is_map(block["cache_control"]),
        label: block_label(block)
      }
    end)
  end

  defp block_label(%{"truncated_items" => count}) when is_integer(count),
    do: "truncated_items=#{count}"

  defp block_label(%{"text" => text}) when is_binary(text) do
    cond do
      String.starts_with?(text, "<info>") ->
        "<info>"

      String.starts_with?(text, "<chapter ") ->
        chapter_name(text)

      true ->
        message_id_from_text(text) || text |> String.split("\n", parts: 2) |> List.first()
    end
  end

  defp block_label(%{"type" => type}) when is_binary(type), do: type
  defp block_label(_block), do: "block"

  defp chapter_name(text) when is_binary(text) do
    case Regex.run(~r/<chapter name="([^"]+)"/, text) do
      [_, name] -> "<chapter #{name}>"
      _ -> "<chapter>"
    end
  end

  defp message_id_from_text(text) when is_binary(text) do
    case Regex.run(~r/message_id="(\d+)"/, text) do
      [_, id] -> id
      _ -> nil
    end
  end

  defp event_seq(metadata) when is_map(metadata) do
    metadata
    |> Map.get("seq")
    |> case do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp format_breakpoints([]), do: "-"

  defp format_breakpoints(rows) do
    rows
    |> Enum.map_join(", ", fn row -> "#{row.idx}:#{row.label}" end)
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end
end
