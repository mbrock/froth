defmodule Froth.Mix.Follow do
  @moduledoc false

  alias Froth.Follow.{Entry, Filter, Source}
  alias Froth.Mix.LiveNode

  @default_tail 80

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

    subscribe_remote_events!(node)

    IO.puts("Connected to #{node}")
    IO.puts(follow_banner(filter, mode))

    Process.flag(:trap_exit, true)

    render_recent_history(mode, filter, tail)
    loop(node, %{mode: mode, filter: filter})
  end

  defp parse_args(args) do
    OptionParser.parse(args,
      strict: [
        help: :boolean,
        errors: :boolean,
        debug: :boolean,
        cycle: :string,
        span: :string,
        tail: :integer
      ]
    )
  end

  defp usage do
    """
    Usage: bin/follow [EVENT_PREFIX] [options]

    Subscribe to the `events` pub/sub topic on the running node and
    print each event as a single line. A prefix argument narrows the
    stream (e.g. `bin/follow froth.agent` only shows agent events).

        bin/follow
        bin/follow --tail 120
        bin/follow froth.agent
        bin/follow --cycle 01ABC...
        bin/follow --errors

    Options:
      --tail N     Number of recent matching entries to print before following
      --errors     Render only warn/error entries
      --debug      Include debug-level events (llm.edit, sse deltas, span starts)
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

  # Subscribe to the remote node's "events" topic by spawning a
  # process there that forwards each broadcast back to us. Phoenix
  # pubsub is node-local, so we can't just subscribe from here.
  defp subscribe_remote_events!(node) do
    me = self()

    case :rpc.call(node, __MODULE__, :start_remote_subscriber, [me]) do
      {:ok, _pid} ->
        :ok

      {:badrpc, reason} ->
        abort("Could not subscribe to events on #{node}: #{inspect(reason)}")

      other ->
        abort("Could not subscribe to events on #{node}: #{inspect(other)}")
    end
  end

  @doc false
  def start_remote_subscriber(target_pid) when is_pid(target_pid) do
    pid =
      spawn(fn ->
        :ok = Phoenix.PubSub.subscribe(Froth.PubSub, "events")
        ref = Process.monitor(target_pid)
        forward_loop(target_pid, ref)
      end)

    {:ok, pid}
  end

  defp forward_loop(target_pid, ref) do
    receive do
      {:event, _event} = msg ->
        send(target_pid, msg)
        forward_loop(target_pid, ref)

      {:DOWN, ^ref, :process, ^target_pid, _reason} ->
        :ok

      _other ->
        forward_loop(target_pid, ref)
    end
  end

  defp follow_banner(filter, mode) do
    filter_summary = Filter.summary(filter)

    prefix =
      if filter_summary == [],
        do: "",
        else: " (#{Enum.join(filter_summary, ", ")})"

    "Following events#{prefix} #{mode_label(mode)}\n"
  end

  defp parse_mode(opts) do
    cond do
      opts[:errors] -> :errors
      opts[:debug] -> :raw
      true -> :smart
    end
  end

  defp mode_label(:errors), do: "(errors only)"
  defp mode_label(:raw), do: "(with debug)"
  defp mode_label(_), do: "(info+)"

  defp parse_event_prefix([]), do: nil
  defp parse_event_prefix([filter]), do: filter

  defp loop(node, %{mode: mode, filter: filter} = state) do
    receive do
      {:event, event} ->
        entry = Entry.from_event(event)

        if Filter.matches?(entry, filter) and Entry.visible?(entry, mode) do
          IO.puts(render_line(entry))
        end

        loop(node, state)

      {:nodedown, ^node} ->
        abort("Disconnected from #{node}")
    end
  end

  defp render_recent_history(_mode, _filter, 0), do: :ok

  defp render_recent_history(mode, filter, tail) do
    entries =
      Source.recent_entries(filter: filter, limit: tail * 4)
      |> Enum.reverse()
      |> Enum.filter(&Entry.visible?(&1, mode))
      |> Enum.take(-tail)

    if entries != [] do
      IO.puts(
        "Recent matching entries (last #{length(entries)} shown):\n"
      )

      Enum.each(entries, &IO.puts(render_line(&1)))
      IO.write("\n")
    end

    :ok
  end

  # Two lines per event:
  #   TIME  LVL  family.kind  cycle=… span=… (duration)
  #                key=value  key=value  …
  # The second line is indented to align under the family.kind column,
  # and is omitted when there is no interesting metadata. Colors are
  # light — family hue, faint timestamps and keys, level badges for
  # warn/error.
  defp render_line(%Entry{} = entry) do
    ansi = IO.ANSI.enabled?()
    header = render_header(entry, ansi)

    case render_meta_line(entry, ansi) do
      nil -> header
      meta -> header <> "\n" <> meta
    end
  end

  @indent String.duplicate(" ", 19)

  defp render_header(%Entry{} = entry, ansi) do
    time = dim(format_time(entry.at), ansi)
    level = level_tag(entry.level, ansi)
    name = event_name(entry, ansi)
    scope = scope_tag(entry, ansi)
    duration = duration_tag(entry.duration_ms, ansi)

    [time, "  ", level, "  ", name]
    |> maybe_append(scope)
    |> maybe_append(duration)
    |> IO.iodata_to_binary()
  end

  defp render_meta_line(%Entry{metadata: metadata}, ansi) do
    case meta_pairs(metadata) do
      [] ->
        nil

      pairs ->
        body =
          pairs
          |> Enum.map_join("  ", fn {k, v} ->
            dim(k, ansi) <> "=" <> v
          end)

        @indent <> truncate(body, 160)
    end
  end

  defp event_name(%Entry{event: event, family: family, kind: kind}, ansi) do
    if String.starts_with?(event, "froth.") do
      colorize_family(family, ansi) <> dim(".", ansi) <> kind
    else
      event
    end
  end

  defp scope_tag(%Entry{cycle_id: cycle_id, span_id: span_id}, ansi) do
    [
      cycle_id && "cycle=" <> String.slice(cycle_id, 0, 12),
      span_id && "span=" <> String.slice(span_id, 0, 12)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" -> ""
      s -> dim(s, ansi)
    end
  end

  defp duration_tag(nil, _ansi), do: ""
  defp duration_tag(ms, ansi), do: dim("(#{ms}ms)", ansi)

  defp maybe_append(iodata, ""), do: iodata
  defp maybe_append(iodata, extra), do: [iodata, "  ", extra]

  defp format_time(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%H:%M:%S.%f") |> String.slice(0, 12)

  defp format_time(%NaiveDateTime{} = dt),
    do: Calendar.strftime(dt, "%H:%M:%S.%f") |> String.slice(0, 12)

  defp format_time(_), do: "--:--:--.---"

  defp level_tag(:error, ansi),
    do: color(ansi, [:red, :bright], "ERR")

  defp level_tag(:warn, ansi),
    do: color(ansi, [:yellow, :bright], "WRN")

  defp level_tag(:debug, ansi),
    do: dim("dbg", ansi)

  defp level_tag(_, _ansi), do: "   "

  defp meta_pairs(metadata) when map_size(metadata) == 0, do: []

  defp meta_pairs(metadata) do
    metadata
    |> Map.drop([
      "system_time",
      "blob_ref",
      "cycle_id",
      "span_id",
      "parent_id",
      "seq",
      "kind",
      "head_id"
    ])
    |> Enum.sort_by(&pair_weight/1)
    |> Enum.take(6)
    |> Enum.map(fn {k, v} -> {k, short(v)} end)
  end

  # Pull a few particularly useful keys to the front (provider, model,
  # tool_name, text_preview, reason, error, outcome), then alphabetical.
  defp pair_weight({key, _}) do
    priority = %{
      "provider" => 0,
      "model" => 1,
      "tool_name" => 2,
      "outcome" => 3,
      "reason" => 4,
      "error" => 5,
      "text_preview" => 6,
      "role" => 7
    }

    {Map.get(priority, key, 100), key}
  end

  defp short(v) when is_binary(v) do
    if String.length(v) > 60, do: String.slice(v, 0, 60) <> "…", else: v
  end

  defp short(v) when is_integer(v) or is_float(v) or is_boolean(v),
    do: to_string(v)

  defp short(nil), do: "nil"
  defp short(v), do: inspect(v, limit: 4, printable_limit: 60)

  defp truncate(text, max) when byte_size(text) > max,
    do: binary_part(text, 0, max) <> "…"

  defp truncate(text, _max), do: text

  # Family palette: light touch, easy on dark and light terminals.
  defp colorize_family(family, ansi) do
    codes =
      case family do
        "agent" -> [:cyan]
        "http" -> [:faint]
        "anthropic" -> [:magenta]
        "openai" -> [:magenta]
        "gemini" -> [:magenta]
        "google" -> [:magenta]
        "grok" -> [:magenta]
        "xai" -> [:magenta]
        "llm" -> [:magenta]
        "codex" -> [:green]
        "telegram" -> [:blue]
        "tools" -> [:yellow]
        "tasks" -> [:yellow]
        "browser" -> [:yellow]
        "web" -> [:yellow]
        "headlines" -> [:green]
        "replicate" -> [:green]
        "podcast" -> [:green]
        _ -> [:default_color]
      end

    color(ansi, codes, family)
  end

  defp color(true, codes, text) do
    IO.iodata_to_binary([
      Enum.map(codes, &IO.ANSI.format_fragment(&1, true)),
      text,
      IO.ANSI.reset()
    ])
  end

  defp color(false, _codes, text), do: text

  defp dim(text, ansi), do: color(ansi, [:faint], text)

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

  defp abort(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end
