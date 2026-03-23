defmodule Mix.Tasks.Froth.Follow do
  @moduledoc "Connect to the running node and follow telemetry events."
  @shortdoc "Follow telemetry events on the running node"

  use Mix.Task

  alias Froth.Follow.{Entry, Filter, Projector, Renderer}

  @handler_id "froth-follow"

  @impl Mix.Task
  def run(args) do
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
        strict: [raw: :boolean, errors: :boolean, cycle: :string, span: :string]
      )

    mode = parse_mode(opts)

    filter =
      Filter.new(
        event_prefix: parse_filter(remaining),
        cycle_id: opts[:cycle],
        span_id: opts[:span]
      )

    events = fetch_events(node)
    events = filter_events(events, Filter.event_segments(filter))

    follower = self()

    handler = fn event_name, measurements, metadata, _config ->
      send(follower, {:telemetry_event, event_name, measurements, metadata})
    end

    :rpc.call(node, :telemetry, :attach_many, [@handler_id, events, handler, nil])

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
      loop(mode, filter)
    after
      :rpc.call(node, :telemetry, :detach, [@handler_id])
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

  defp parse_filter([]), do: nil

  defp parse_filter([filter | _]) do
    filter
    |> String.split(".")
    |> Enum.reject(&(&1 == ""))
  end

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
end
