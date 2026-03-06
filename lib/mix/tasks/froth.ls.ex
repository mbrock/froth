defmodule Mix.Tasks.Froth.Ls do
  @moduledoc """
  Print a compact runtime/data summary via RPC to the running node.

  Currently shows:
  - configured Telegram sessions and whether they appear to be running
  - per-session message/chat counts from `telegram_messages`
  - recent chats ordered by latest stored message

      mix froth.ls
      mix froth.ls --limit 30
      mix froth.ls --session mbrockman
  """
  @shortdoc "List Telegram sessions and chats via RPC"

  use Mix.Task

  @default_node "froth@igloo"

  @impl Mix.Task
  def run(args) do
    {opts, _positional, invalid} =
      OptionParser.parse(args, strict: [limit: :integer, session: :string])

    if invalid != [] do
      abort("Unknown arguments: #{Enum.map_join(invalid, " ", &elem(&1, 0))}")
    end

    limit = Keyword.get(opts, :limit, 20)
    session_id = Keyword.get(opts, :session)

    if limit <= 0 do
      abort("--limit must be a positive integer")
    end

    node = connect!()
    gl = Process.group_leader()

    Mix.shell().info("Inspecting #{node}...")

    case :erpc.call(node, Froth.RPC, :eval, [gl, rpc_code(limit, session_id)]) do
      %{sessions: sessions, chats: chats} = payload when is_list(sessions) and is_list(chats) ->
        print_sessions(payload.sessions)
        IO.puts("")
        print_chats(payload.chats, limit, session_id)

      other ->
        Mix.shell().error("Unexpected response: #{inspect(other, limit: :infinity)}")
        System.halt(1)
    end
  end

  defp rpc_code(limit, session_id) do
    """
    import Ecto.Query

    session_filter = #{inspect(session_id)}
    limit = #{limit}

    running_sessions = MapSet.new(Froth.Telegram.list_sessions())

    session_rows =
      Froth.Repo.all(
        from(s in Froth.Telegram.SessionConfig,
          order_by: [asc: s.id],
          select: %{
            id: s.id,
            enabled: s.enabled,
            phone_number: s.phone_number,
            bot_token: s.bot_token
          }
        ),
        log: false
      )

    session_stats =
      Froth.Repo.all(
        from(m in "telegram_messages",
          group_by: m.telegram_session_id,
          select: %{
            session_id: m.telegram_session_id,
            message_count: count("*"),
            chat_count: count(fragment("distinct ?", m.chat_id)),
            latest_date: max(m.date),
            latest_inserted_at: max(m.inserted_at)
          }
        ),
        log: false
      )
      |> Map.new(fn stat -> {stat.session_id, stat} end)

    sessions =
      Enum.map(session_rows, fn row ->
        stat = Map.get(session_stats, row.id, %{})

        %{
          id: row.id,
          enabled: row.enabled,
          mode: if(is_binary(row.bot_token) and row.bot_token != "", do: "bot", else: "user"),
          running: MapSet.member?(running_sessions, row.id),
          message_count: Map.get(stat, :message_count, 0),
          chat_count: Map.get(stat, :chat_count, 0),
          latest_date: Map.get(stat, :latest_date),
          latest_inserted_at: Map.get(stat, :latest_inserted_at)
        }
      end)

    chat_query =
      from(m in "telegram_messages",
        group_by: [m.telegram_session_id, m.chat_id],
        select: %{
          session_id: m.telegram_session_id,
          chat_id: m.chat_id,
          message_count: count("*"),
          first_date: min(m.date),
          last_date: max(m.date),
          latest_inserted_at: max(m.inserted_at)
        },
        order_by: [desc: max(m.inserted_at)],
        limit: ^limit
      )

    chat_query =
      if is_binary(session_filter) and session_filter != "" do
        from(m in chat_query, where: m.session_id == ^session_filter)
      else
        chat_query
      end

    chats = Froth.Repo.all(chat_query, log: false)

    %{sessions: sessions, chats: chats}
    """
  end

  defp print_sessions([]) do
    IO.puts("Telegram sessions: (none)")
  end

  defp print_sessions(sessions) do
    IO.puts("Telegram sessions:")

    Enum.each(sessions, fn session ->
      latest =
        case session.latest_date do
          unix when is_integer(unix) -> " latest=#{format_unix(unix)}"
          _ -> ""
        end

      IO.puts(
        "  #{session.id} mode=#{session.mode} enabled=#{session.enabled} running=#{session.running} " <>
          "chats=#{session.chat_count} messages=#{session.message_count}#{latest}"
      )
    end)
  end

  defp print_chats([], _limit, session_id) do
    suffix = if session_id, do: " for session #{session_id}", else: ""
    IO.puts("Recent chats#{suffix}: (none)")
  end

  defp print_chats(chats, limit, session_id) do
    suffix = if session_id, do: " for session #{session_id}", else: ""
    IO.puts("Recent chats#{suffix} (top #{limit} by latest stored message):")

    Enum.each(chats, fn chat ->
      IO.puts(
        "  session=#{chat.session_id} chat=#{chat.chat_id} messages=#{chat.message_count} " <>
          "first=#{format_unix(chat.first_date)} last=#{format_unix(chat.last_date)}"
      )
    end)
  end

  defp format_unix(unix) when is_integer(unix) do
    unix
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  defp connect! do
    node =
      System.get_env("RPC_NODE", @default_node)
      |> String.to_atom()

    cookie =
      case System.get_env("ERLANG_COOKIE") do
        nil -> File.read!(Path.expand("~/.erlang.cookie")) |> String.trim()
        val -> val
      end

    Node.start(:"froth_ls_#{System.pid()}", name_domain: :shortnames)
    Node.set_cookie(String.to_atom(cookie))

    unless Node.connect(node) do
      abort("Could not connect to #{node}")
    end

    node
  end

  defp abort(msg) do
    Mix.shell().error(msg)
    System.halt(1)
  end
end
