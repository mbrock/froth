defmodule Froth.Repo.DataMigrations.RecoverCycleItemsFromEvents do
  import Ecto.Query

  alias Froth.Agent.{Cycle, CycleItem}
  alias Froth.{Event, ObjectStore, Repo}

  @event_kinds [
    "message.appended",
    "llm.completed",
    "cycle.started",
    "cycle.completed",
    "cycle.failed",
    "cycle.cancelled",
    "tool.started",
    "tool.completed",
    "tool.failed",
    "tool.timed_out",
    "control.outcome"
  ]

  @semantic_kinds MapSet.new(
                    @event_kinds --
                      [
                        "message.appended",
                        "llm.completed"
                      ]
                  )

  @batch_size 500

  def run do
    cycle_ids =
      Repo.all(from(c in Cycle, select: c.id), timeout: :infinity)
      |> MapSet.new()

    query =
      from(e in Event,
        where:
          like(e.event, "froth.agent.%") and
            fragment("?->>'kind' = ANY(?)", e.metadata, ^@event_kinds),
        order_by: [
          asc: fragment("?->>'cycle_id'", e.metadata),
          asc: fragment("COALESCE((?->>'seq')::bigint, -1)", e.metadata),
          asc: e.inserted_at,
          asc: e.id
        ],
        select: %{
          metadata: e.metadata,
          inserted_at: e.inserted_at
        }
      )

    recovered =
      Repo.transaction(
        fn ->
          query
          |> Repo.stream(max_rows: @batch_size)
          |> Enum.reduce(initial_state(cycle_ids), &recover_event/2)
          |> flush()
          |> Map.fetch!(:recovered)
        end,
        timeout: :infinity
      )

    case recovered do
      {:ok, count} ->
        IO.puts("Recovered #{count} ordered cycle items.")
        :ok

      {:error, reason} ->
        raise "cycle history recovery failed: #{inspect(reason)}"
    end
  end

  def repair_empty_assistant_messages do
    result =
      Repo.query!(
        """
        UPDATE cycle_items AS message
        SET
          payload = jsonb_set(
            message.payload,
            '{content}',
            (
              SELECT jsonb_agg(
                jsonb_build_object(
                  'type', 'tool_use',
                  'id', tool.payload->>'tool_use_id',
                  'name', tool.payload->>'tool_name',
                  'input', COALESCE(tool.payload->'input', '{}'::jsonb)
                )
                ORDER BY tool.seq
              )
              FROM cycle_items AS tool
              WHERE tool.cycle_id = message.cycle_id
                AND tool.item_kind = 'tool.use'
                AND tool.seq > message.seq
                AND tool.seq < COALESCE(
                  (
                    SELECT MIN(next_message.seq)
                    FROM cycle_items AS next_message
                    WHERE next_message.cycle_id = message.cycle_id
                      AND next_message.role IS NOT NULL
                      AND next_message.seq > message.seq
                  ),
                  9223372036854775807
                )
            )
          ),
          updated_at = NOW()
        WHERE message.item_kind = 'message.assistant'
          AND jsonb_array_length(message.payload->'content') = 0
          AND EXISTS (
            SELECT 1
            FROM cycle_items AS tool
            WHERE tool.cycle_id = message.cycle_id
              AND tool.item_kind = 'tool.use'
              AND tool.seq > message.seq
              AND tool.seq < COALESCE(
                (
                  SELECT MIN(next_message.seq)
                  FROM cycle_items AS next_message
                  WHERE next_message.cycle_id = message.cycle_id
                    AND next_message.role IS NOT NULL
                    AND next_message.seq > message.seq
                ),
                9223372036854775807
              )
          )
        """,
        [],
        timeout: :infinity
      )

    IO.puts("Repaired #{result.num_rows} tool-only assistant messages.")
    :ok
  end

  def recover_pre_event_telegram_history do
    result =
      Repo.query!(
        """
        WITH missing AS (
          SELECT
            cycles.id AS cycle_id,
            cycles.inserted_at AS cycle_inserted_at,
            COALESCE(cycles.updated_at, cycles.inserted_at) AS cycle_updated_at,
            links.bot_id,
            links.chat_id,
            links.reply_to
          FROM agent_cycles AS cycles
          JOIN telegram_cycle_links AS links
            ON links.cycle_id = cycles.id
          WHERE links.reply_to IS NOT NULL
            AND NOT EXISTS (
              SELECT 1
              FROM cycle_items AS item
              WHERE item.cycle_id = cycles.id
            )
        ),
        triggers AS (
          SELECT DISTINCT ON (missing.cycle_id)
            missing.cycle_id,
            0::bigint AS seq,
            'user' AS role,
            'message.user' AS item_kind,
            telegram.message_id,
            telegram.date,
            telegram.raw
          FROM missing
          JOIN telegram_messages AS telegram
            ON telegram.chat_id = missing.chat_id
           AND telegram.message_id = missing.reply_to
          ORDER BY
            missing.cycle_id,
            (telegram.telegram_session_id = 'mbrockman') DESC,
            telegram.telegram_session_id
        ),
        outputs AS (
          SELECT
            missing.cycle_id,
            ROW_NUMBER() OVER (
              PARTITION BY missing.cycle_id
              ORDER BY telegram.date, telegram.message_id
            )::bigint AS seq,
            'agent' AS role,
            'message.assistant' AS item_kind,
            telegram.message_id,
            telegram.date,
            telegram.raw
          FROM missing
          JOIN telegram_messages AS telegram
            ON telegram.chat_id = missing.chat_id
           AND (telegram.raw->'reply_to'->>'message_id')::bigint =
                 missing.reply_to
           AND telegram.telegram_session_id =
                 CASE
                   WHEN missing.bot_id = 'charlie' THEN 'charlie'
                   ELSE 'agentbot'
                 END
           AND telegram.raw->>'is_outgoing' = 'true'
           AND telegram.date BETWEEN
                 EXTRACT(EPOCH FROM missing.cycle_inserted_at)::integer - 10
                 AND
                 EXTRACT(EPOCH FROM missing.cycle_updated_at)::integer + 300
        ),
        recovered AS (
          SELECT * FROM triggers
          UNION ALL
          SELECT * FROM outputs
        )
        INSERT INTO cycle_items (
          id,
          cycle_id,
          seq,
          role,
          item_kind,
          payload,
          inserted_at,
          updated_at
        )
        SELECT
          gen_random_uuid(),
          recovered.cycle_id,
          recovered.seq,
          recovered.role,
          recovered.item_kind,
          jsonb_build_object(
            'content',
            jsonb_build_array(
              jsonb_build_object(
                'type', 'text',
                'text', COALESCE(
                  recovered.raw->'content'->'text'->>'text',
                  recovered.raw->'content'->'caption'->>'text',
                  FORMAT(
                    '[Telegram %s message %s]',
                    COALESCE(recovered.raw->'content'->>'@type', 'unknown'),
                    recovered.message_id
                  )
                )
              )
            ),
            'metadata',
            jsonb_build_object(
              'recovered_from', 'telegram_cycle_link',
              'telegram_message_id', recovered.message_id,
              'original_agent_transcript_unavailable', true
            )
          ),
          timezone('UTC', to_timestamp(recovered.date)),
          timezone('UTC', to_timestamp(recovered.date))
        FROM recovered
        ON CONFLICT (cycle_id, seq) DO NOTHING
        """,
        [],
        timeout: :infinity
      )

    IO.puts(
      "Recovered #{result.num_rows} pre-event Telegram messages with explicit provenance."
    )

    :ok
  end

  defp initial_state(cycle_ids) do
    %{
      cycle_ids: cycle_ids,
      current_cycle_id: nil,
      last_llm: nil,
      pending_tool_results: [],
      batch: [],
      recovered: 0
    }
  end

  defp recover_event(row, state) do
    metadata = row.metadata
    cycle_id = metadata["cycle_id"]

    state =
      if cycle_id == state.current_cycle_id do
        state
      else
        %{
          state
          | current_cycle_id: cycle_id,
            last_llm: nil,
            pending_tool_results: []
        }
      end

    cond do
      not MapSet.member?(state.cycle_ids, cycle_id) ->
        state

      metadata["kind"] == "llm.completed" ->
        %{state | last_llm: full_payload(metadata)}

      metadata["kind"] == "message.appended" ->
        recover_message(row, state)

      MapSet.member?(@semantic_kinds, metadata["kind"]) ->
        recover_semantic_item(row, state)

      true ->
        state
    end
  end

  defp recover_message(row, state) do
    metadata = row.metadata
    role = metadata["role"]
    role_atom = if role == "agent", do: :agent, else: :user

    {content, message_metadata, pending_tool_results} =
      case role do
        "agent" ->
          {
            get_in(state.last_llm || %{}, ["response", "content"]) ||
              text_content(metadata["text_preview"]),
            get_in(state.last_llm || %{}, ["response", "metadata"]) ||
              metadata["metadata"] || %{},
            state.pending_tool_results
          }

        "user" when state.pending_tool_results != [] ->
          {
            Enum.reverse(state.pending_tool_results),
            metadata["metadata"] || %{},
            []
          }

        "user" ->
          {
            text_content(metadata["text_preview"]),
            metadata["metadata"] || %{},
            []
          }
      end

    item = %{
      id: Ecto.ULID.generate(),
      cycle_id: state.current_cycle_id,
      seq: metadata["seq"],
      role: role_atom,
      item_kind:
        if(role == "agent", do: "message.assistant", else: "message.user"),
      payload: %{
        "content" => content || [],
        "metadata" => message_metadata || %{}
      },
      span_id: metadata["span_id"],
      inserted_at: row.inserted_at,
      updated_at: row.inserted_at
    }

    state
    |> Map.put(:pending_tool_results, pending_tool_results)
    |> enqueue(item)
  end

  defp recover_semantic_item(row, state) do
    metadata = row.metadata
    kind = metadata["kind"]
    payload = full_payload(metadata)

    state =
      if kind in ["tool.completed", "tool.failed", "tool.timed_out"] do
        result = recovered_tool_result(payload, kind)

        Map.update!(
          state,
          :pending_tool_results,
          &[result | &1]
        )
      else
        state
      end

    item = %{
      id: Ecto.ULID.generate(),
      cycle_id: state.current_cycle_id,
      seq: metadata["seq"],
      role: nil,
      item_kind: item_kind(kind),
      payload:
        payload
        |> Map.drop(["cycle_id", "seq", "kind", "blob_ref"]),
      span_id: metadata["span_id"],
      inserted_at: row.inserted_at,
      updated_at: row.inserted_at
    }

    enqueue(state, item)
  end

  defp enqueue(state, item) do
    state = %{state | batch: [item | state.batch]}

    if length(state.batch) >= @batch_size do
      flush(state)
    else
      state
    end
  end

  defp flush(%{batch: []} = state), do: state

  defp flush(state) do
    {count, _} =
      Repo.insert_all(
        CycleItem,
        Enum.reverse(state.batch),
        on_conflict: :nothing,
        conflict_target: [:cycle_id, :seq],
        timeout: :infinity
      )

    %{state | batch: [], recovered: state.recovered + count}
  end

  defp full_payload(%{"blob_ref" => blob_ref} = metadata)
       when is_binary(blob_ref) do
    case ObjectStore.get(blob_ref) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, payload} when is_map(payload) ->
            Map.merge(metadata, payload)

          _ ->
            metadata
        end

      _ ->
        metadata
    end
  end

  defp full_payload(metadata), do: metadata

  defp text_content(text) when is_binary(text),
    do: [%{"type" => "text", "text" => text}]

  defp text_content(_text), do: []

  defp recovered_tool_result(payload, kind) do
    result_type = payload["result_type"]
    error = payload["error"]

    %{
      "type" => "tool_result",
      "tool_use_id" => payload["tool_use_id"],
      "content" => payload["result"] || error || "tool result unavailable"
    }
    |> maybe_mark_error(kind != "tool.completed" or result_type == "error")
  end

  defp maybe_mark_error(result, true), do: Map.put(result, "is_error", true)
  defp maybe_mark_error(result, false), do: result

  defp item_kind("cycle.started"), do: "cycle.started"
  defp item_kind("cycle.completed"), do: "cycle.completed"
  defp item_kind("cycle.failed"), do: "cycle.failed"
  defp item_kind("cycle.cancelled"), do: "cycle.cancelled"
  defp item_kind("tool.started"), do: "tool.use"
  defp item_kind("tool.completed"), do: "tool.result"
  defp item_kind("tool.failed"), do: "tool.result"
  defp item_kind("tool.timed_out"), do: "tool.result"
  defp item_kind("control.outcome"), do: "control.outcome"
end

Application.ensure_all_started(:ecto_sql)
{:ok, _repo} = Froth.Repo.start_link()

alias Froth.Repo.DataMigrations.RecoverCycleItemsFromEvents, as: Recovery

cond do
  "--repair-only" in System.argv() ->
    Recovery.repair_empty_assistant_messages()

  "--telegram-only" in System.argv() ->
    Recovery.recover_pre_event_telegram_history()

  true ->
    Recovery.run()
    Recovery.repair_empty_assistant_messages()
    Recovery.recover_pre_event_telegram_history()
end
