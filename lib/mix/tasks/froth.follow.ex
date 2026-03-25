defmodule Mix.Tasks.Froth.Follow do
  @moduledoc "Connect to the running node and follow telemetry events."
  @shortdoc "Follow telemetry events on the running node"

  use Mix.Task

  alias Froth.Follow.{Entry, Filter, Projector, Renderer, Source}

  @handler_id "froth-follow"

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
      render_recent_history(mode, filter, tail)
      loop(mode, filter)
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

  defp loop(mode, filter) do
    receive do
      {:telemetry_event, event_name, measurements, metadata} ->
        entry = Projector.from_live(event_name, measurements, metadata)

        if Filter.matches?(entry, filter) and Entry.visible?(entry, mode) do
          IO.write(Renderer.to_ansi(entry, mode))
          IO.write("\n")
        end
    end

    loop(mode, filter)
  end

  defp render_recent_history(_mode, _filter, 0), do: :ok

  defp render_recent_history(mode, filter, tail) do
    entries =
      Source.recent_entries(filter: filter, limit: tail)
      |> Enum.filter(&Entry.visible?(&1, mode))
      |> Enum.reverse()

    if entries != [] do
      Mix.shell().info("Recent matching entries:\n")

      Enum.each(entries, fn entry ->
        IO.write(Renderer.to_ansi(entry, mode))
        IO.write("\n")
      end)

      IO.write("\n")
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

  defp abort(message) do
    Mix.shell().error(message)
    System.halt(1)
  end
end
