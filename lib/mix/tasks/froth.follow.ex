defmodule Mix.Tasks.Froth.Follow do
  @moduledoc "Connect to the running node and follow telemetry events."
  @shortdoc "Follow telemetry events on the running node"

  use Mix.Task

  alias Froth.Follow.{Entry, Filter, Projector, Renderer, Source, Timeline}

  @handler_id "froth-follow"
  @render_state_limit 2_000

  @impl Mix.Task
  def run(args) do
    ensure_repo_started!()

    node = Froth.Cluster.rpc_target_node()

    cookie =
      case System.get_env("ERLANG_COOKIE") do
        nil -> File.read!(Path.expand("~/.erlang.cookie")) |> String.trim()
        val -> val
      end

    Node.start(:"follow_#{System.pid()}", :shortnames)
    Node.set_cookie(String.to_atom(cookie))

    unless Node.connect(node) do
      Mix.shell().error("Could not connect to #{node}")
      System.halt(1)
    end

    {opts, remaining, _invalid} =
      OptionParser.parse(args,
        strict: [raw: :boolean, errors: :boolean, cycle: :string, span: :string, tail: :integer]
      )

    mode = parse_mode(opts)
    tail = max(opts[:tail] || 20, 0)

    filter =
      Filter.new(
        event_prefix: parse_event_prefix(remaining),
        cycle_id: opts[:cycle],
        span_id: opts[:span]
      )

    events = fetch_events(node)
    events = filter_events(events, Filter.event_segments(filter))
    handler_id = unique_handler_id()

    case :rpc.call(node, :telemetry, :attach_many, [
           handler_id,
           events,
           &__MODULE__.handle_telemetry_event/4,
           %{pid: self()}
         ]) do
      :ok -> :ok
      {:badrpc, reason} -> abort("Could not attach telemetry handler: #{inspect(reason)}")
      other -> abort("Could not attach telemetry handler: #{inspect(other)}")
    end

    Mix.shell().info("Connected to #{node}")
    filter_summary = Filter.summary(filter)

    Mix.shell().info([
      "Following #{length(events)} telemetry events",
      if(filter_summary == [], do: "", else: " (#{Enum.join(filter_summary, ", ")})"),
      " ",
      mode_label(mode),
      "\n"
    ])

    Process.flag(:trap_exit, true)

    try do
      state = render_recent_history(mode, filter, tail)

      loop(%{
        mode: mode,
        filter: filter,
        matched_entries: state.matched_entries,
        visible_entries: state.visible_entries
      })
    after
      :rpc.call(node, :telemetry, :detach, [handler_id])
    end
  end

  defp fetch_events(node) do
    :rpc.call(node, Froth.Telemetry, :events, [])
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
  defp parse_event_prefix([filter | _]), do: filter

  defp filter_events(events, nil), do: events

  defp filter_events(events, prefix) do
    Enum.filter(events, fn event ->
      event
      |> Enum.map(&Atom.to_string/1)
      |> List.starts_with?(prefix)
    end)
  end

  defp loop(%{mode: mode, filter: filter} = state) do
    receive do
      {:telemetry_event, event_name, measurements, metadata} ->
        entry = Projector.from_live(event_name, measurements, metadata)

        state = update_render_state(state, entry, filter, mode)
        loop(state)
    end
  end

  defp render_recent_history(_mode, _filter, 0) do
    %{matched_entries: [], visible_entries: []}
  end

  defp render_recent_history(mode, filter, tail) do
    matched_entries =
      Source.recent_entries(filter: filter, limit: tail)
      |> Enum.reverse()

    visible_entries = Enum.filter(matched_entries, &Entry.visible?(&1, mode))

    if visible_entries != [] do
      Mix.shell().info("Recent matching entries:\n")

      tree_map = Timeline.tree_map(visible_entries)
      cycle_summaries = Timeline.cycle_summaries(matched_entries)

      Enum.each(visible_entries, fn entry ->
        IO.write(Renderer.to_ansi(entry, mode, tree_prefix: tree_prefix(tree_map, entry)))
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

        IO.write(Renderer.to_ansi(entry, mode, tree_prefix: tree_prefix(tree_map, entry)))
        IO.write("\n")
        maybe_render_cycle_summary(entry, cycle_summaries, mode)
      end

      %{state | matched_entries: matched_entries, visible_entries: visible_entries}
    else
      state
    end
  end

  def handle_telemetry_event(event_name, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, event_name, measurements, metadata})
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
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> abort("Could not start Froth.Repo: #{inspect(reason)}")
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
    Mix.shell().error(message)
    System.halt(1)
  end
end
