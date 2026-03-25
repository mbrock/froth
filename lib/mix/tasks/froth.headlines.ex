defmodule Mix.Tasks.Froth.Headlines do
  @moduledoc """
  Start headline registration on the running node and follow the run live.

      mix froth.headlines
      mix froth.headlines --spam
      mix froth.headlines --chat -1003690254489
      mix froth.headlines --model gpt-5.4-mini
  """
  @shortdoc "Run headline registration with live follow output"

  use Mix.Task

  require Logger

  alias Froth.Agent.Message
  alias Froth.Follow.{Entry, Projector, Renderer, Timeline}

  @handler_id "froth-headlines"
  @render_state_limit 2_000
  @start_timeout_ms 30_000
  @relevant_events [
    [:froth, :agent, :cycle, :start],
    [:froth, :agent, :cycle, :stop],
    [:froth, :agent, :control, :outcome],
    [:froth, :agent, :think, :start],
    [:froth, :agent, :think, :stop],
    [:froth, :agent, :tool, :started],
    [:froth, :agent, :tool, :completed],
    [:froth, :agent, :tool, :failed],
    [:froth, :agent, :tool, :timed_out],
    [:froth, :headlines, :registered]
  ]

  @impl Mix.Task
  def run(args) do
    with_quiet_debug_logs(fn ->
      {opts, _remaining, invalid} =
        OptionParser.parse(args,
          strict: [chat: :integer, model: :string, reset: :boolean, spam: :boolean]
        )

      if invalid != [] do
        abort("Unknown arguments: #{Enum.map_join(invalid, " ", &elem(&1, 0))}")
      end

      node = connect!()
      gl = Process.group_leader()
      chat_id = opts[:chat] || resolve_chat_id(node, gl)
      model = opts[:model]
      spam = Keyword.get(opts, :spam, false)
      maybe_reset_registered_headlines(node, chat_id, opts)
      handler_id = unique_handler_id()

      case :rpc.call(node, :telemetry, :attach_many, [
             handler_id,
             @relevant_events,
             &__MODULE__.handle_telemetry_event/4,
             %{pid: self()}
           ]) do
        :ok -> :ok
        {:badrpc, reason} -> abort("Could not attach telemetry handler: #{inspect(reason)}")
        other -> abort("Could not attach telemetry handler: #{inspect(other)}")
      end

      Mix.shell().info(start_message(chat_id, node, model, spam))

      runner_pid = start_remote_headlines(node, chat_id, model, spam)
      runner_ref = Process.monitor(runner_pid)

      try do
        state = %{
          node: node,
          chat_id: chat_id,
          runner_pid: runner_pid,
          runner_ref: runner_ref,
          cycle_id: nil,
          matched_entries: [],
          visible_entries: [],
          stream_phase: nil
        }

        state
        |> await_cycle_start()
        |> loop()
      after
        :rpc.call(node, :telemetry, :detach, [handler_id])
      end
    end)
  end

  def handle_telemetry_event(event_name, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, event_name, measurements, metadata})
  end

  defp await_cycle_start(state) do
    receive do
      {:froth_headlines_started, runner_pid, cycle_id}
      when runner_pid == state.runner_pid and is_binary(cycle_id) ->
        Mix.shell().info("Following cycle #{cycle_id}.\n")
        send(runner_pid, {:froth_headlines_continue, cycle_id})
        %{state | cycle_id: cycle_id}

      {:froth_headlines_failed, runner_pid, reason, formatted}
      when runner_pid == state.runner_pid ->
        abort("Headline run failed: #{reason}\n\n#{formatted}")

      {:DOWN, ref, :process, pid, reason}
      when ref == state.runner_ref and pid == state.runner_pid ->
        abort("Headline runner exited before start: #{inspect(reason)}")

      {:telemetry_event, _event_name, _measurements, _metadata} ->
        await_cycle_start(state)
    after
      @start_timeout_ms ->
        abort("Timed out waiting for headline cycle to start.")
    end
  end

  defp loop(state) do
    receive do
      {:telemetry_event, event_name, measurements, metadata} ->
        state
        |> safely_render_telemetry(event_name, measurements, metadata)
        |> loop()

      {:froth_headlines_stream_item, runner_pid, cycle_id, item}
      when runner_pid == state.runner_pid and cycle_id == state.cycle_id ->
        state
        |> safely_render_stream_item(item)
        |> loop()

      {:froth_headlines_finished, runner_pid, cycle_id, output}
      when runner_pid == state.runner_pid and cycle_id == state.cycle_id ->
        flush_stream_phase(state)
        Mix.shell().info("\nHeadline registration completed.")
        maybe_print_final_output(output)

      {:froth_headlines_failed, runner_pid, reason, formatted}
      when runner_pid == state.runner_pid ->
        flush_stream_phase(state)
        abort("Headline run failed: #{reason}\n\n#{formatted}")

      {:DOWN, ref, :process, pid, :normal}
      when ref == state.runner_ref and pid == state.runner_pid ->
        state
        |> flush_stream_phase()
        |> loop()

      {:DOWN, ref, :process, pid, reason}
      when ref == state.runner_ref and pid == state.runner_pid ->
        flush_stream_phase(state)
        abort("Headline runner exited: #{inspect(reason)}")
    end
  end

  defp maybe_render_telemetry(state, event_name, measurements, metadata) do
    entry = Projector.from_live(event_name, measurements, metadata)

    if relevant_entry?(entry, event_name, metadata, state) do
      matched_entries = limit_entries(state.matched_entries ++ [entry])
      visible? = Entry.visible?(entry, :smart)

      visible_entries =
        if visible? do
          limit_entries(state.visible_entries ++ [entry])
        else
          state.visible_entries
        end

      state = %{state | matched_entries: matched_entries, visible_entries: visible_entries}

      if visible? do
        flush_stream_phase(state)
        render_entry(entry, matched_entries, visible_entries, measurements, metadata)
      end

      state
    else
      state
    end
  end

  defp safely_render_telemetry(state, event_name, measurements, metadata) do
    maybe_render_telemetry(state, event_name, measurements, metadata)
  rescue
    error ->
      report_render_warning(state, "telemetry #{format_event_name(event_name)}", error)
  catch
    kind, reason ->
      report_render_warning(state, "telemetry #{format_event_name(event_name)}", {kind, reason})
  end

  defp relevant_entry?(%Entry{event: "froth.headlines.registered"}, _event_name, metadata, state) do
    normalize_chat_id(metadata[:chat_id] || metadata["chat_id"]) ==
      Integer.to_string(state.chat_id)
  end

  defp relevant_entry?(%Entry{cycle_id: cycle_id}, _event_name, _metadata, state)
       when is_binary(cycle_id) and is_binary(state.cycle_id) do
    cycle_id == state.cycle_id
  end

  defp relevant_entry?(_entry, _event_name, _metadata, _state), do: false

  defp render_entry(
         %Entry{event: "froth.headlines.registered"} = entry,
         _matched,
         _visible,
         measurements,
         metadata
       ) do
    count = measurements[:count] || measurements["count"] || 0
    date = metadata[:date] || metadata["date"] || "unknown-date"

    IO.write([
      IO.ANSI.faint(),
      format_entry_time(entry.at),
      IO.ANSI.reset(),
      " ",
      IO.ANSI.green(),
      "headlines",
      IO.ANSI.reset(),
      " ",
      Integer.to_string(count),
      " registered for ",
      to_string(date),
      "\n"
    ])

    render_registered_headlines(metadata)
  end

  defp render_entry(entry, matched_entries, visible_entries, _measurements, _metadata) do
    tree_map = Timeline.tree_map(visible_entries)
    cycle_summaries = Timeline.cycle_summaries(matched_entries)

    IO.write(Renderer.to_ansi(entry, :smart, tree_prefix: tree_prefix(tree_map, entry)))
    IO.write("\n")
    maybe_render_cycle_summary(entry, cycle_summaries)
  end

  defp safely_render_stream_item(state, item) do
    render_stream_item(state, item)
  rescue
    error ->
      report_render_warning(state, "stream item", error)
  catch
    kind, reason ->
      report_render_warning(state, "stream item", {kind, reason})
  end

  defp render_stream_item(state, {:stream, {:thinking_delta, %{"delta" => delta}}})
       when is_binary(delta) do
    state = begin_stream_phase(state, :thinking)
    IO.write([IO.ANSI.faint(), delta, IO.ANSI.reset()])
    state
  end

  defp render_stream_item(state, {:stream, {:thinking_stop, _payload}}) do
    flush_stream_phase(state)
  end

  defp render_stream_item(state, {:stream, {:thinking_summary, %{"thinking" => thinking}}})
       when is_binary(thinking) do
    state = begin_stream_phase(state, :thinking)
    IO.write([IO.ANSI.faint(), truncate(thinking, 8_000), IO.ANSI.reset()])
    flush_stream_phase(state)
  end

  defp render_stream_item(state, {:stream, {:text_delta, delta}}) when is_binary(delta) do
    state = begin_stream_phase(state, :reply)
    IO.write(delta)
    state
  end

  defp render_stream_item(state, {:event, _event, %Message{role: :agent} = message}) do
    case message_thinking_text(message) do
      nil ->
        state

      thinking ->
        state = begin_stream_phase(state, :thinking)
        IO.write([IO.ANSI.faint(), truncate(thinking, 8_000), IO.ANSI.reset()])
        flush_stream_phase(state)
    end
  end

  defp render_stream_item(state, {:stream, {:tool_use_stop, data}}) when is_map(data) do
    state = flush_stream_phase(state)
    IO.write(format_tool_call(data))
    IO.write("\n")
    state
  end

  defp render_stream_item(state, {:event, _event, %Message{role: :user} = message}) do
    case tool_result_text(message) || preview_message_text(message) do
      nil ->
        state

      preview ->
        state = flush_stream_phase(state)

        IO.write([
          IO.ANSI.faint(),
          "tool< ",
          truncate(preview, 320),
          IO.ANSI.reset(),
          "\n"
        ])

        state
    end
  end

  defp render_stream_item(state, _item), do: state

  defp begin_stream_phase(%{stream_phase: phase} = state, phase), do: state

  defp begin_stream_phase(state, phase) do
    state = flush_stream_phase(state)

    label =
      case phase do
        :thinking -> [IO.ANSI.faint(), "thinking> ", IO.ANSI.reset()]
        :reply -> [IO.ANSI.cyan(), "reply> ", IO.ANSI.reset()]
      end

    IO.write(label)
    %{state | stream_phase: phase}
  end

  defp flush_stream_phase(%{stream_phase: nil} = state), do: state

  defp flush_stream_phase(state) do
    IO.write("\n")
    %{state | stream_phase: nil}
  end

  defp format_tool_call(%{"name" => name} = data) when is_binary(name) do
    header = [IO.ANSI.green(), "tool> ", IO.ANSI.reset(), name]

    case format_tool_call_details(name, Map.get(data, "input", %{})) do
      nil ->
        preview = preview_json(Map.get(data, "input", %{}))

        [
          header,
          " ",
          IO.ANSI.faint(),
          preview,
          IO.ANSI.reset()
        ]

      details ->
        [header, "\n", details]
    end
  end

  defp format_tool_call(data) do
    [
      IO.ANSI.green(),
      "tool> ",
      IO.ANSI.reset(),
      IO.ANSI.faint(),
      truncate(inspect(data, limit: 20, printable_limit: 400), 320),
      IO.ANSI.reset()
    ]
  end

  defp format_tool_call_details("register_headlines", %{"date" => date, "headlines" => headlines})
       when is_binary(date) and is_list(headlines) do
    [
      "  ",
      IO.ANSI.faint(),
      "date=",
      IO.ANSI.reset(),
      date,
      "\n",
      headlines
      |> Enum.map_join("\n", fn headline -> "  " <> format_headline(headline) end)
    ]
  end

  defp format_tool_call_details(_name, _input), do: nil

  defp preview_message_text(%Message{} = message) do
    Message.extract_text(message) || inspect(message.content, limit: 20, printable_limit: 400)
  end

  defp tool_result_text(%Message{} = message) do
    message
    |> message_blocks()
    |> Enum.flat_map(fn
      %{"type" => "tool_result", "content" => content} -> [normalize_tool_result_text(content)]
      _ -> []
    end)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n")
    end
  end

  defp message_thinking_text(%Message{} = message) do
    message
    |> message_blocks()
    |> Enum.flat_map(fn
      %{"type" => "thinking", "thinking" => thinking} when is_binary(thinking) -> [thinking]
      _ -> []
    end)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  defp message_blocks(%Message{content: %{"_wrapped" => value}}),
    do: normalize_message_blocks(value)

  defp message_blocks(%Message{content: value}), do: normalize_message_blocks(value)

  defp normalize_message_blocks(blocks) when is_list(blocks), do: blocks
  defp normalize_message_blocks(%{} = block), do: [block]
  defp normalize_message_blocks(_value), do: []

  defp normalize_tool_result_text(content) when is_binary(content), do: content

  defp normalize_tool_result_text(content) when is_list(content) do
    content
    |> Enum.map_join("\n", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      item -> inspect(item, limit: 20, printable_limit: 300)
    end)
  end

  defp normalize_tool_result_text(content), do: inspect(content, limit: 20, printable_limit: 400)

  defp preview_json(value) do
    encoded =
      case Jason.encode(value) do
        {:ok, json} -> json
        {:error, _reason} -> inspect(value, limit: 20, printable_limit: 400)
      end

    truncate(encoded, 320)
  end

  defp maybe_print_final_output(output) when is_binary(output) do
    text = String.trim(output)

    if text != "" do
      Mix.shell().info("\nFinal output:\n" <> text)
    end
  end

  defp maybe_print_final_output(_output), do: :ok

  defp start_message(chat_id, node, nil, false) do
    "Starting headline registration for chat #{chat_id} on #{node} with Telegram posting disabled..."
  end

  defp start_message(chat_id, node, nil, true) do
    "Starting headline registration for chat #{chat_id} on #{node} with Telegram posting enabled..."
  end

  defp start_message(chat_id, node, model, false) when is_binary(model) do
    "Starting headline registration for chat #{chat_id} on #{node} with model #{model} and Telegram posting disabled..."
  end

  defp start_message(chat_id, node, model, true) when is_binary(model) do
    "Starting headline registration for chat #{chat_id} on #{node} with model #{model} and Telegram posting enabled..."
  end

  defp report_render_warning(state, subject, %_{} = error) do
    state = flush_stream_phase(state)
    Mix.shell().error("follow render warning (#{subject}): #{Exception.message(error)}")
    state
  end

  defp report_render_warning(state, subject, other) do
    state = flush_stream_phase(state)
    Mix.shell().error("follow render warning (#{subject}): #{inspect(other)}")
    state
  end

  defp format_event_name(event_name) when is_list(event_name) do
    Enum.map_join(event_name, ".", &Atom.to_string/1)
  end

  defp format_event_name(_event_name), do: "unknown"

  defp start_remote_headlines(node, chat_id, model, spam)
       when is_integer(chat_id) and (is_binary(model) or is_nil(model)) and is_boolean(spam) do
    caller = self()

    case :erpc.call(node, fn ->
           caller = caller
           chat_id = chat_id
           model = model
           spam = spam

           spawn(fn ->
             try do
               start_opts =
                 [chat_id: chat_id]
                 |> maybe_put_start_opt(:model, model)
                 |> Keyword.put(:spam, spam)

               {cycle, stream} = Froth.Headlines.start(start_opts)
               cycle_id = cycle.id
               send(caller, {:froth_headlines_started, self(), cycle.id})

               receive do
                 {:froth_headlines_continue, ^cycle_id} ->
                   :ok
               after
                 30_000 ->
                   raise "timed out waiting for local follower to attach"
               end

               output =
                 Enum.reduce(stream, nil, fn item, acc ->
                   send(caller, {:froth_headlines_stream_item, self(), cycle.id, item})

                   case item do
                     {:event, _event, %Froth.Agent.Message{role: :agent} = message} ->
                       Froth.Agent.Message.extract_text(message) || message.content

                     _ ->
                       acc
                   end
                 end)

               send(caller, {:froth_headlines_finished, self(), cycle.id, output})
             rescue
               error ->
                 send(
                   caller,
                   {:froth_headlines_failed, self(), Exception.message(error),
                    Exception.format(:error, error, __STACKTRACE__)}
                 )
             catch
               kind, reason ->
                 send(
                   caller,
                   {:froth_headlines_failed, self(), inspect({kind, reason}),
                    Exception.format(kind, reason, __STACKTRACE__)}
                 )
             end
           end)
         end) do
      pid when is_pid(pid) ->
        pid

      other ->
        abort("Could not start headline runner: #{inspect(other)}")
    end
  rescue
    error ->
      abort("Could not start headline runner: #{Exception.message(error)}")
  end

  defp resolve_chat_id(node, gl) do
    code = """
    import Ecto.Query
    Froth.Repo.all(
      from(s in Froth.ChatSummary, select: s.chat_id, distinct: true),
      log: false
    )
    """

    case :erpc.call(node, Froth.RPC, :eval, [gl, code]) do
      [chat_id] ->
        chat_id

      [] ->
        abort("No summaries found. Cannot determine chat_id.")

      ids when is_list(ids) ->
        abort(
          "Multiple chats have summaries: #{Enum.join(ids, ", ")}. " <>
            "Pass --chat to choose one."
        )
    end
  end

  defp maybe_reset_registered_headlines(node, chat_id, opts)
       when is_integer(chat_id) and is_list(opts) do
    if opts[:reset] do
      deleted = reset_registered_headlines(node, chat_id)

      Mix.shell().info(
        "Deleted #{deleted} saved headline registration(s) for chat #{chat_id} before starting."
      )
    end
  end

  defp reset_registered_headlines(node, chat_id) when is_integer(chat_id) do
    chat_id_string = Integer.to_string(chat_id)

    :erpc.call(node, fn ->
      import Ecto.Query

      {count, _} =
        Froth.Repo.delete_all(
          from(e in Froth.Event,
            where:
              e.event == "froth.headlines.registered" and
                fragment("?->>'chat_id' = ?", e.metadata, ^chat_id_string)
          ),
          log: false
        )

      count
    end)
  end

  defp maybe_put_start_opt(keyword, _key, nil), do: keyword
  defp maybe_put_start_opt(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp connect! do
    node = Froth.Cluster.rpc_target_node()

    cookie =
      case System.get_env("ERLANG_COOKIE") do
        nil -> File.read!(Path.expand("~/.erlang.cookie")) |> String.trim()
        val -> val
      end

    Node.start(:"headlines_#{System.pid()}", :shortnames)
    Node.set_cookie(String.to_atom(cookie))

    unless Node.connect(node) do
      abort("Could not connect to #{node}")
    end

    node
  end

  defp maybe_render_cycle_summary(entry, cycle_summaries)
       when entry.family == "cycle" and entry.kind in ["stop", "completed", "failed", "cancelled"] do
    case Map.get(cycle_summaries, entry.cycle_id) do
      nil ->
        :ok

      summary ->
        IO.write(Renderer.cycle_summary_to_ansi(summary))
        IO.write("\n")
    end
  end

  defp maybe_render_cycle_summary(_entry, _cycle_summaries), do: :ok

  defp format_entry_time(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%H:%M:%S.%f") |> String.slice(0, 12)

  defp format_entry_time(%NaiveDateTime{} = dt),
    do: Calendar.strftime(dt, "%H:%M:%S.%f") |> String.slice(0, 12)

  defp format_entry_time(_value), do: "--:--:--.---"

  defp tree_prefix(tree_map, entry) do
    entry
    |> entry_id()
    |> then(&Map.get(tree_map, &1, %{prefix: ""}))
    |> Map.fetch!(:prefix)
  end

  defp entry_id(%Entry{id: id}), do: to_string(id)

  defp limit_entries(entries), do: Enum.take(entries, -@render_state_limit)

  defp render_registered_headlines(metadata) when is_map(metadata) do
    metadata
    |> Map.get(:headlines, Map.get(metadata, "headlines", []))
    |> case do
      headlines when is_list(headlines) and headlines != [] ->
        Enum.each(headlines, fn headline ->
          IO.write(["  ", format_headline(headline), "\n"])
        end)

      _ ->
        :ok
    end
  end

  defp render_registered_headlines(_metadata), do: :ok

  defp format_headline(%{"emoji" => emoji, "title" => title} = headline)
       when is_binary(emoji) and is_binary(title) do
    formatted_time =
      case headline_time_window(headline) do
        nil -> ""
        value -> " " <> value
      end

    "#{emoji} #{title}#{formatted_time}"
  end

  defp format_headline(%{emoji: emoji, title: title} = headline)
       when is_binary(emoji) and is_binary(title) do
    format_headline(%{
      "emoji" => emoji,
      "title" => title,
      "from_time" => Map.get(headline, :from_time),
      "to_time" => Map.get(headline, :to_time)
    })
  end

  defp format_headline(%{"title" => title}) when is_binary(title), do: title
  defp format_headline(%{title: title}) when is_binary(title), do: title

  defp format_headline(headline),
    do: truncate(inspect(headline, limit: 10, printable_limit: 200), 200)

  defp headline_time_window(%{"from_time" => from_time, "to_time" => to_time})
       when is_binary(from_time) and is_binary(to_time) do
    with {:ok, from_dt, _} <- DateTime.from_iso8601(from_time),
         {:ok, to_dt, _} <- DateTime.from_iso8601(to_time) do
      "(" <>
        Calendar.strftime(from_dt, "%H:%M") <>
        "-" <> Calendar.strftime(to_dt, "%H:%M") <> " UTC)"
    else
      _ -> nil
    end
  end

  defp headline_time_window(_headline), do: nil

  defp normalize_chat_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_chat_id(value) when is_binary(value), do: value
  defp normalize_chat_id(_value), do: nil

  defp truncate(value, max) when is_binary(value) and byte_size(value) > max,
    do: String.slice(value, 0, max) <> "..."

  defp truncate(value, _max), do: value

  defp unique_handler_id do
    "#{@handler_id}-#{System.pid()}-#{System.unique_integer([:positive])}"
  end

  defp with_quiet_debug_logs(fun) when is_function(fun, 0) do
    previous_level = Logger.level()

    Logger.configure(level: :warning)

    try do
      fun.()
    after
      Logger.configure(level: previous_level)
    end
  end

  defp abort(message) do
    Mix.shell().error(message)
    System.halt(1)
  end
end
