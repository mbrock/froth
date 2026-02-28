defmodule Mix.Tasks.Froth.Follow do
  @moduledoc "Connect to the running node and follow telemetry events."
  @shortdoc "Follow telemetry events on the running node"

  use Mix.Task

  @default_node "froth@igloo"
  @handler_id "froth-follow"

  @dim "\e[2m"
  @reset "\e[0m"
  @bold "\e[1m"
  @red "\e[31m"
  @yellow "\e[33m"

  @impl Mix.Task
  def run(args) do
    node =
      System.get_env("RPC_NODE", @default_node)
      |> String.to_atom()

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

    prefix_filter = parse_filter(args)
    events = fetch_events(node)
    events = filter_events(events, prefix_filter)

    follower = self()

    handler = fn event_name, measurements, metadata, _config ->
      send(follower, {:telemetry_event, event_name, measurements, metadata})
    end

    :rpc.call(node, :telemetry, :attach_many, [@handler_id, events, handler, nil])

    Mix.shell().info("Connected to #{node}")
    Mix.shell().info("Following #{length(events)} telemetry events#{if prefix_filter, do: " (filter: #{prefix_filter})"}\n")

    Process.flag(:trap_exit, true)

    try do
      loop()
    after
      :rpc.call(node, :telemetry, :detach, [@handler_id])
    end
  end

  defp fetch_events(node) do
    :rpc.call(node, Froth.Telemetry, :events, [])
  end

  defp parse_filter([]), do: nil

  defp parse_filter([filter | _]) do
    filter
    |> String.split(".")
    |> Enum.map(&String.to_atom/1)
  end

  defp filter_events(events, nil), do: events

  defp filter_events(events, prefix) do
    Enum.filter(events, fn event ->
      List.starts_with?(event, prefix)
    end)
  end

  defp loop do
    receive do
      {:telemetry_event, event_name, measurements, metadata} ->
        format_event(event_name, measurements, metadata)
    end

    loop()
  end

  defp format_event(event_name, measurements, metadata) do
    ts = DateTime.utc_now() |> Calendar.strftime("%H:%M:%S.%f") |> String.slice(0, 12)
    name = Enum.join(event_name, ".")
    level_color = level_color(event_name)

    IO.write([
      @dim, ts, @reset, " ",
      level_color, name, @reset
    ])

    duration = format_duration(measurements)
    if duration, do: IO.write([" ", @bold, duration, @reset])

    pairs = format_metadata(metadata)
    if pairs != [], do: IO.write([" ", pairs])

    IO.write("\n")
  end

  defp format_duration(%{duration: native}) when is_integer(native) do
    ms = System.convert_time_unit(native, :native, :millisecond)
    "#{ms}ms"
  end

  defp format_duration(_), do: nil

  defp format_metadata(metadata) when map_size(metadata) == 0, do: []

  defp format_metadata(metadata) do
    metadata
    |> Map.drop([:span_id, :parent_id, :system_time])
    |> Enum.sort_by(fn {k, _} -> Atom.to_string(k) end)
    |> Enum.map(fn {k, v} ->
      [@dim, Atom.to_string(k), "=", @reset, format_val(v)]
    end)
    |> Enum.intersperse(" ")
  end

  defp format_val(v) when is_binary(v) and byte_size(v) > 80, do: String.slice(v, 0, 80) <> "..."
  defp format_val(v) when is_binary(v), do: v
  defp format_val(v) when is_atom(v), do: Atom.to_string(v)
  defp format_val(v) when is_integer(v), do: Integer.to_string(v)
  defp format_val(v) when is_float(v), do: Float.to_string(v)
  defp format_val(true), do: "true"
  defp format_val(false), do: "false"
  defp format_val(v), do: inspect(v, limit: 5, printable_limit: 80)

  defp level_color([:froth, _, _, :exception]), do: @red
  defp level_color([:froth, _, _, :stop]), do: @bold
  defp level_color([:froth, :http, :sse | _]), do: @dim
  defp level_color([:froth, _, _, :start]), do: @dim
  defp level_color(_), do: @yellow
end
