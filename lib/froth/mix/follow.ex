defmodule Froth.Mix.Follow do
  @moduledoc false

  alias Froth.Follow.{Entry, Filter, Projector, Renderer, Source, Timeline}
  alias Froth.Mix.LiveNode

  @handler_id "froth-follow"
  @default_tail 80
  @render_state_limit 2_000

  @spec main([String.t()]) :: no_return()
  def main(args) do
    ensure_repo_started!()

    {opts, remaining, invalid} = parse_args(args)

    if opts[:help] do
      IO.write(usage())
      System.halt(0)
    end

    validate_args!(remaining, invalid)

    node = LiveNode.connect!("follow")
    Node.monitor(node, true)

    mode = parse_mode(opts)
    tail = max(opts[:tail] || @default_tail, 0)

    filter =
      Filter.new(
        event_prefix: parse_event_prefix(remaining),
        cycle_id: opts[:cycle],
        span_id: opts[:span]
      )

    events = fetch_events(node, filter)
    handler_id = unique_handler_id()

    attach_handler!(node, handler_id, events)

    IO.puts("Connected to #{node}")
    IO.puts(follow_banner(events, filter, mode))

    Process.flag(:trap_exit, true)

    try do
      state = render_recent_history(mode, filter, tail)

      loop(node, %{
        mode: mode,
        filter: filter,
        matched_entries: state.matched_entries,
        visible_entries: state.visible_entries
      })
    after
      :rpc.call(node, :telemetry, :detach, [handler_id])
    end
  end

  def handle_telemetry_event(event_name, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, event_name, measurements, metadata})
  end

  defp parse_args(args) do
    OptionParser.parse(args,
      strict: [
        help: :boolean,
        raw: :boolean,
        errors: :boolean,
        cycle: :string,
        span: :string,
        tail: :integer
      ]
    )
  end

  defp usage do
    """
    Usage: bin/follow [EVENT_PREFIX] [options]

    Follow telemetry events on the running node.

        bin/follow
        bin/follow --tail 120
        bin/follow froth.agent
        bin/follow --cycle 01ABC...
        bin/follow --errors

    Options:
      --tail N     Number of recent matching entries to print before following
      --raw        Render raw event names and metadata
      --errors     Render only warn/error entries
      --cycle ID   Restrict to a cycle id prefix
      --span ID    Restrict to a span id prefix
      --help       Show this help
    """
  end

  defp validate_args!([], []), do: :ok

  defp validate_args!(remaining, invalid) do
    invalid_args =
      invalid
      |> Enum.map(fn
        {name, nil} -> "--#{name}"
        {name, value} -> "--#{name}=#{value}"
      end)

    too_many_args? = length(remaining) > 1

    cond do
      invalid_args != [] ->
        abort(
          "Unknown options: #{Enum.join(invalid_args, ", ")}\n\n#{usage()}"
        )

      too_many_args? ->
        abort("Expected at most one EVENT_PREFIX argument.\n\n#{usage()}")

      true ->
        :ok
    end
  end

  defp attach_handler!(node, handler_id, events) do
    case :rpc.call(node, :telemetry, :attach_many, [
           handler_id,
           events,
           &__MODULE__.handle_telemetry_event/4,
           %{pid: self()}
         ]) do
      :ok ->
        :ok

      {:badrpc, reason} ->
        abort("Could not attach telemetry handler: #{inspect(reason)}")

      other ->
        abort("Could not attach telemetry handler: #{inspect(other)}")
    end
  end

  defp fetch_events(node, filter) do
    case :rpc.call(node, Froth.Telemetry, :events, []) do
      events when is_list(events) ->
        filter_events(events, Filter.event_segments(filter))

      {:badrpc, reason} ->
        abort("Could not fetch telemetry events: #{inspect(reason)}")

      other ->
        abort("Could not fetch telemetry events: #{inspect(other)}")
    end
  end

  defp follow_banner(events, filter, mode) do
    filter_summary = Filter.summary(filter)

    [
      "Following #{length(events)} telemetry events",
      if(filter_summary == [],
        do: "",
        else: " (#{Enum.join(filter_summary, ", ")})"
      ),
      " ",
      mode_label(mode),
      "\n"
    ]
  end

  defp parse_mode(opts) do
    cond do
      opts[:raw] -> :raw
      opts[:errors] -> :errors
      true -> :smart
    end
  end

  defp mode_label(:raw), do: "(raw mode)"
  defp mode_label(:errors), do: "(errors mode)"
  defp mode_label(:smart), do: "(smart mode)"

  defp parse_event_prefix([]), do: nil
  defp parse_event_prefix([filter]), do: filter

  defp filter_events(events, nil), do: events

  defp filter_events(events, prefix) do
    Enum.filter(events, fn event ->
      event
      |> Enum.map(&Atom.to_string/1)
      |> List.starts_with?(prefix)
    end)
  end

  defp loop(node, %{mode: mode, filter: filter} = state) do
    receive do
      {:telemetry_event, event_name, measurements, metadata} ->
        entry = Projector.from_live(event_name, measurements, metadata)

        state = update_render_state(state, entry, filter, mode)
        loop(node, state)

      {:nodedown, ^node} ->
        abort("Disconnected from #{node}")
    end
  end

  defp render_recent_history(_mode, _filter, 0) do
    %{matched_entries: [], visible_entries: []}
  end

  defp render_recent_history(mode, filter, tail) do
    matched_entries =
      Source.recent_entries(
        filter: filter,
        limit: history_fetch_limit(tail, mode)
      )
      |> Enum.reverse()

    visible_entries =
      matched_entries
      |> Enum.filter(&Entry.visible?(&1, mode))
      |> Enum.take(-tail)

    if visible_entries != [] do
      IO.puts(
        "Recent matching entries (last #{length(visible_entries)} shown):"
      )

      IO.puts("")

      tree_map = Timeline.tree_map(visible_entries)
      cycle_summaries = Timeline.cycle_summaries(matched_entries)

      Enum.each(visible_entries, fn entry ->
        IO.write(
          Renderer.to_ansi(entry, mode,
            tree_prefix: tree_prefix(tree_map, entry)
          )
        )

        IO.write("\n")
        maybe_render_cycle_summary(entry, cycle_summaries, mode)
      end)

      IO.write("\n")
    end

    %{
      matched_entries: limit_entries(matched_entries),
      visible_entries: limit_entries(visible_entries)
    }
  end

  defp history_fetch_limit(tail, :raw), do: tail

  defp history_fetch_limit(tail, _mode) when is_integer(tail) and tail > 0 do
    max(tail * 4, tail)
  end

  defp history_fetch_limit(_tail, _mode), do: 0

  defp update_render_state(state, entry, filter, mode) do
    if Filter.matches?(entry, filter) do
      matched_entries = limit_entries(state.matched_entries ++ [entry])
      visible? = Entry.visible?(entry, mode)

      visible_entries =
        if visible? do
          limit_entries(state.visible_entries ++ [entry])
        else
          state.visible_entries
        end

      if visible? do
        tree_map = Timeline.tree_map(visible_entries)
        cycle_summaries = Timeline.cycle_summaries(matched_entries)

        IO.write(
          Renderer.to_ansi(entry, mode,
            tree_prefix: tree_prefix(tree_map, entry)
          )
        )

        IO.write("\n")
        maybe_render_cycle_summary(entry, cycle_summaries, mode)
      end

      %{
        state
        | matched_entries: matched_entries,
          visible_entries: visible_entries
      }
    else
      state
    end
  end

  defp ensure_repo_started! do
    Mix.Task.run("loadpaths")
    Mix.Task.run("app.config")

    if Process.whereis(Froth.Repo) do
      :ok
    else
      Application.ensure_all_started(:postgrex)
      Application.ensure_all_started(:ecto_sql)

      case Froth.Repo.start_link() do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          abort("Could not start Froth.Repo: #{inspect(reason)}")
      end
    end
  end

  defp unique_handler_id do
    "#{@handler_id}-#{System.pid()}-#{System.unique_integer([:positive])}"
  end

  defp limit_entries(entries), do: Enum.take(entries, -@render_state_limit)

  defp tree_prefix(tree_map, entry) do
    entry
    |> entry_id()
    |> then(&Map.get(tree_map, &1, %{prefix: ""}))
    |> Map.fetch!(:prefix)
  end

  defp entry_id(%Entry{id: id}), do: to_string(id)

  defp maybe_render_cycle_summary(entry, cycle_summaries, mode)
       when mode in [:smart, :errors] and entry.family == "cycle" and
              entry.kind in ["stop", "completed", "failed", "cancelled"] do
    case Map.get(cycle_summaries, entry.cycle_id) do
      nil ->
        :ok

      summary ->
        IO.write(Renderer.cycle_summary_to_ansi(summary))
        IO.write("\n")
    end
  end

  defp maybe_render_cycle_summary(_entry, _cycle_summaries, _mode), do: :ok

  defp abort(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end
