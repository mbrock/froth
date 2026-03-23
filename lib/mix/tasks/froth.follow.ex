defmodule Mix.Tasks.Froth.Follow do
  @moduledoc "Connect to the running node and follow telemetry events."
  @shortdoc "Follow telemetry events on the running node"

  use Mix.Task

  alias Froth.Follow.{Entry, Projector, Renderer}

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
      OptionParser.parse(args, strict: [raw: :boolean, errors: :boolean])

    mode = parse_mode(opts)
    prefix_filter = parse_filter(remaining)
    events = fetch_events(node)
    events = filter_events(events, prefix_filter)

    follower = self()

    handler = fn event_name, measurements, metadata, _config ->
      send(follower, {:telemetry_event, event_name, measurements, metadata})
    end

    :rpc.call(node, :telemetry, :attach_many, [@handler_id, events, handler, nil])

    Mix.shell().info("Connected to #{node}")

    Mix.shell().info(
      "Following #{length(events)} telemetry events#{if prefix_filter, do: " (filter: #{Enum.join(prefix_filter, ".")})"} #{mode_label(mode)}\n"
    )

    Process.flag(:trap_exit, true)

    try do
      loop(mode, prefix_filter)
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

  defp loop(mode, prefix_filter) do
    receive do
      {:telemetry_event, event_name, measurements, metadata} ->
        entry = Projector.from_live(event_name, measurements, metadata)

        if matches_prefix?(entry, prefix_filter) and Entry.visible?(entry, mode) do
          IO.write(Renderer.to_ansi(entry, mode))
          IO.write("\n")
        end
    end

    loop(mode, prefix_filter)
  end

  defp matches_prefix?(_entry, nil), do: true

  defp matches_prefix?(entry, prefix) do
    entry.event
    |> String.split(".")
    |> List.starts_with?(prefix)
  end
end
