defmodule Mix.Tasks.MigrateInferenceSessions do
  @shortdoc "Migrate telegram_inference_sessions data into agent_cycles/messages/events + telegram_cycle_links"
  @moduledoc """
  Converts old InferenceSession records into the new Agent table structure.

  Each session becomes:
  - One agent_cycle
  - A linked chain of agent_messages (from api_messages)
  - One agent_event per message (tracking head advancement)
  - One telegram_cycle_link row (preserving bot_id, chat_id, reply_to)

  Only sessions with status "done" are migrated by default.
  Pass --all to include error/stopped sessions too.

  Safe to run multiple times — skips sessions that already have a link row.
  """

  use Mix.Task
  import Ecto.Query

  alias Froth.Repo

  @batch_size 50

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    include_all = "--all" in args

    statuses = if include_all, do: ~w(done error stopped), else: ~w(done)

    already_migrated_ids =
      Repo.all(
        from(l in "telegram_cycle_links",
          where: not is_nil(l.legacy_inference_session_id),
          select: l.legacy_inference_session_id
        ),
        log: false
      )
      |> MapSet.new()

    sessions =
      Repo.all(
        from(s in "telegram_inference_sessions",
          where: s.status in ^statuses,
          order_by: [asc: s.id],
          select: %{
            id: s.id,
            bot_id: s.bot_id,
            chat_id: s.chat_id,
            reply_to: s.reply_to,
            api_messages: s.api_messages,
            status: s.status,
            inserted_at: s.inserted_at,
            updated_at: s.updated_at
          }
        ),
        log: false,
        timeout: :infinity
      )
      |> Enum.reject(&MapSet.member?(already_migrated_ids, &1.id))

    total = length(sessions)
    Mix.shell().info("Migrating #{total} inference sessions (#{Enum.join(statuses, ", ")})")
    Mix.shell().info("Already migrated: #{MapSet.size(already_migrated_ids)}")

    sessions
    |> Enum.chunk_every(@batch_size)
    |> Enum.with_index(1)
    |> Enum.each(fn {batch, batch_num} ->
      migrated =
        Enum.count(batch, fn session ->
          case migrate_session(session) do
            :ok ->
              true

            {:error, reason} ->
              Mix.shell().error("  session #{session.id}: #{reason}")
              false
          end
        end)

      progress = min(batch_num * @batch_size, total)
      Mix.shell().info("  #{progress}/#{total} processed (#{migrated} in this batch)")
    end)

    final_count =
      Repo.one(
        from(l in "telegram_cycle_links",
          where: not is_nil(l.legacy_inference_session_id),
          select: count()
        ),
        log: false
      )

    Mix.shell().info("Done. #{final_count} total sessions linked to agent cycles.")
  end

  defp migrate_session(session) do
    api_messages = session.api_messages || []

    if api_messages == [] do
      {:error, "no api_messages"}
    else
      Repo.transaction(
        fn ->
          ts = naive_to_unix_ms(session.inserted_at)
          cycle_id = Ecto.ULID.bingenerate(ts)

          Repo.insert_all("agent_cycles", [
            %{
              id: cycle_id,
              inserted_at: session.inserted_at,
              updated_at: session.updated_at || session.inserted_at
            }
          ])

          {head_id, _seq} =
            api_messages
            |> Enum.with_index()
            |> Enum.reduce({nil, 0}, fn {api_msg, _idx}, {parent_id, seq} ->
              role = map_role(api_msg["role"])
              content = wrap_content(api_msg["content"])

              msg_id = Ecto.ULID.bingenerate(ts + seq)

              Repo.insert_all("agent_messages", [
                %{
                  id: msg_id,
                  role: role,
                  content: content,
                  parent_id: parent_id,
                  inserted_at: session.inserted_at,
                  updated_at: session.updated_at || session.inserted_at
                }
              ])

              event_id = Ecto.ULID.bingenerate(ts + seq)

              Repo.insert_all("agent_events", [
                %{
                  id: event_id,
                  cycle_id: cycle_id,
                  head_id: msg_id,
                  seq: seq,
                  inserted_at: session.inserted_at
                }
              ])

              {msg_id, seq + 1}
            end)

          _ = head_id

          Repo.insert_all("telegram_cycle_links", [
            %{
              cycle_id: cycle_id,
              bot_id: session.bot_id || "unknown",
              chat_id: session.chat_id,
              reply_to: session.reply_to,
              legacy_inference_session_id: session.id,
              inserted_at: DateTime.from_naive!(session.inserted_at, "Etc/UTC")
            }
          ])
        end,
        timeout: :infinity
      )
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp map_role("assistant"), do: "agent"
  defp map_role("user"), do: "user"
  defp map_role(other), do: other || "user"

  defp wrap_content(content) when is_list(content), do: %{"_wrapped" => content}
  defp wrap_content(content) when is_binary(content), do: %{"_wrapped" => content}
  defp wrap_content(content) when is_map(content), do: content
  defp wrap_content(nil), do: %{"_wrapped" => ""}
  defp wrap_content(other), do: %{"_wrapped" => inspect(other)}

  defp naive_to_unix_ms(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  defp naive_to_unix_ms(_), do: System.os_time(:millisecond)
end
